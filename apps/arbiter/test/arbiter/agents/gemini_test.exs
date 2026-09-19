defmodule Arbiter.Agents.GeminiTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini
  alias Arbiter.Agents.SecurityPolicy

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Gemini.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"gemini\"" do
      assert Gemini.provider() == "gemini"
    end

    test "done_sentinel/0 matches `arb done`" do
      assert Regex.match?(Gemini.done_sentinel(), "I am done — arb done")
      refute Regex.match?(Gemini.done_sentinel(), "arb doneness")
    end
  end

  describe "resolved_model/1" do
    setup do
      Arbiter.Agents.Gemini.Config.clear()
      on_exit(&Arbiter.Agents.Gemini.Config.clear/0)

      # resolved_model/1 now branches on which executable would actually run
      # (bd-2fzwlc round 3), so these tests must not depend on whether the
      # host machine happens to have `agy` on PATH — pin PATH to a stub
      # `gemini` binary so they exercise the resolve_model/1 fallback chain
      # deterministically, the same way the default_argv/2 tests below do.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-resolved-model-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "uses an explicit :model override verbatim" do
      assert Gemini.resolved_model(model: "gemini-2.5-flash") == "gemini-2.5-flash"
    end

    test "resolves a :model_tier to a concrete model" do
      assert Gemini.resolved_model(model_tier: "premium") == "gemini-2.5-pro"
      assert Gemini.resolved_model(model_tier: "economy") == "gemini-2.5-flash-lite"
    end

    test "falls back to the gemini-cli default model when nothing is configured" do
      # No explicit model, no tier, no workspace active_model → the gemini-cli's
      # own DEFAULT_GEMINI_MODEL, so the usage ledger still lands a concrete id.
      assert Gemini.resolved_model([]) == "gemini-2.5-pro"
    end

    test "resolves a model for agy the same way as gemini (bd-d2yut8): no more forced nil",
         %{tmp: tmp} do
      # agy does accept `--model` (bd-d2yut8 retires the "agy accepts no
      # model" assumption), so resolution now runs the same explicit →
      # tier → workspace active_model chain as the gemini branch. With
      # nothing configured there is still no known agy-CLI default to fall
      # back to, so that case alone stays nil.
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert Gemini.resolved_model([]) == nil
      assert Gemini.resolved_model(model: "gemini-2.5-flash") == "gemini-2.5-flash"
      assert Gemini.resolved_model(model_tier: "premium") == "gemini-3.1-pro-high"
    end
  end

  describe "default_argv/2 executable resolution" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-gemini-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp, old_path: old_path}
    end

    test "returns {:error, ...} when neither `agy` nor `gemini` is on PATH", %{old_path: old_path} do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "agy or gemini"}} =
                 Gemini.default_argv("hello", [])
      after
        System.put_env("PATH", old_path)
      end
    end

    test "favors `agy` when both `agy` and `gemini` exist", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)
      File.chmod!(gemini_stub, 0o755)

      # Default policy is :bypass — skip-permissions flag IS included.
      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
      refute "--skip-trust" in rest
    end

    test "agy: :bypass security mode includes --dangerously-skip-permissions", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = Gemini.default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
    end

    test "falls back to `gemini` when `agy` is missing", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      # Default policy is :bypass — skip-trust IS included.
      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
      refute "--dangerously-skip-permissions" in rest
    end

    test "gemini: :bypass security mode includes --skip-trust -y", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = Gemini.default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
    end

    test "passes an explicit :model opt through as --model on the agy branch", %{tmp: tmp} do
      # bd-d2yut8: agy does accept `--model` — retire the old assumption
      # that it doesn't and pass the flag through like the gemini branch.
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", model: "gemini-flash")
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "gemini-flash" in rest
    end

    test "resolves :model_tier to a concrete model on the agy branch via the agy tier map",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      for {tier, model} <- [
            {"economy", "gemini-3.8-flash-low"},
            {"standard", "gemini-3.8-flash-medium"},
            {"premium", "gemini-3.1-pro-high"},
            {"flagship", "claude-opus-4-6-thinking"}
          ] do
        {:ok, argv} = Gemini.default_argv("the prompt", model_tier: tier)
        assert "--model" in argv
        assert model in argv
      end
    end

    test "omits --model on the agy branch when nothing resolves", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", [])
      refute "--model" in argv
    end

    test "passes through `:model` opt as `--model <name>` on the gemini branch", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", model: "gemini-flash")
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "gemini-flash" in rest
    end

    test "resolves :model_tier to a concrete Gemini model via the default tier map on the gemini branch",
         %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      for {tier, model} <- [
            {"premium", "gemini-2.5-pro"},
            {"standard", "gemini-2.5-flash"},
            {"economy", "gemini-2.5-flash-lite"}
          ] do
        {:ok, argv} = Gemini.default_argv("the prompt", model_tier: tier)
        assert "--model" in argv
        assert model in argv
      end
    end

    test ":model wins over :model_tier when both are set", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      {:ok, argv} =
        Gemini.default_argv("the prompt", model: "custom-model", model_tier: "economy")

      assert "custom-model" in argv
      refute "gemini-2.5-flash-lite" in argv
    end

    test ":model_tier can be overridden per-workspace via tier_models config", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      Gemini.Config.put_active(%{
        "tier_models" => %{"premium" => "gemini-ultra"}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = Gemini.default_argv("the prompt", model_tier: "premium")
      assert "gemini-ultra" in argv
      refute "gemini-2.5-pro" in argv
    end

    test ":thinking opt maps to --effort <level> by default", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", thinking: "high")
      assert "--effort" in argv
      assert chunk_after(argv, "--effort") == "high"
    end

    test ":thinking none maps to no argv", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", thinking: "none")
      refute "--effort" in argv
    end

    test ":thinking xhigh/max clamp to --effort high", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      for level <- ["xhigh", "max"] do
        {:ok, argv} = Gemini.default_argv("the prompt", thinking: level)
        assert chunk_after(argv, "--effort") == "high"
      end
    end

    test "gemini branch never emits --effort (Finding 1: upstream CLI rejects it)", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      for level <- ["low", "medium", "high", "xhigh", "max"] do
        {:ok, argv} = Gemini.default_argv("the prompt", thinking: level)
        refute "--effort" in argv
      end
    end

    test "agy branch omits --effort when the resolved model already carries an effort suffix (Finding 2)",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      # Every non-flagship agy tier model carries a "-low"/"-medium"/"-high"
      # suffix. Passing a :thinking level that disagrees with the tier's own
      # suffix must still omit --effort — the operator decision is "never
      # both", so the id's own suffix always wins and there is no way to
      # emit two conflicting effort signals.
      {:ok, argv} = Gemini.default_argv("the prompt", model_tier: "premium", thinking: "low")
      assert "--model" in argv
      assert "gemini-3.1-pro-high" in argv
      refute "--effort" in argv
    end

    test "agy branch emits --effort for a suffix-free flagship model", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", model_tier: "flagship", thinking: "high")
      assert "--model" in argv
      assert "claude-opus-4-6-thinking" in argv
      assert "--effort" in argv
      assert chunk_after(argv, "--effort") == "high"
    end

    test ":thinking argv can be overridden per-workspace via thinking_argv config",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      Gemini.Config.put_active(%{
        "thinking_argv" => %{"medium" => ["--thinking-budget", "8192"]}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = Gemini.default_argv("the prompt", thinking: "medium")
      assert "--thinking-budget" in argv
      assert "8192" in argv
    end

    test "gemini CLI path opts into --output-format stream-json", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub | rest] = argv
      assert "--output-format" in rest
      assert "stream-json" in rest
      # The two are adjacent, in order.
      assert chunk_after(rest, "--output-format") == "stream-json"
    end

    test "agy CLI path also adds --output-format stream-json (bd-2fzwlc: agy supports it)", %{
      tmp: tmp
    } do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = Gemini.default_argv("the prompt", [])
      assert "--output-format" in argv
      assert "stream-json" in argv
      assert chunk_after(argv, "--output-format") == "stream-json"
    end
  end

  defp chunk_after(list, flag) do
    list
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.at(1)
  end

  describe "default_argv/2 :timeout_ms → --print-timeout (bd-1xss5z)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-print-timeout-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "agy branch: :timeout_ms is passed through as --print-timeout in seconds", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", timeout_ms: 1_800_000)
      assert "--print-timeout" in argv
      assert chunk_after(argv, "--print-timeout") == "1800s"
    end

    test "agy branch: no --print-timeout flag when :timeout_ms is absent", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", [])
      refute "--print-timeout" in argv
    end

    test "gemini (upstream) branch ignores :timeout_ms — flag is agy-only", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      {:ok, argv} = Gemini.default_argv("the prompt", timeout_ms: 1_800_000)
      refute "--print-timeout" in argv
    end
  end

  describe "spawn_env/1" do
    setup do
      on_exit(fn -> Gemini.Config.clear() end)
      :ok
    end

    test "exports GEMINI_API_KEY and GOOGLE_GENAI_API_KEY from `opts[:api_key]`" do
      assert Gemini.spawn_env(api_key: "my-token") == [
               {"GEMINI_API_KEY", "my-token"},
               {"GOOGLE_GENAI_API_KEY", "my-token"}
             ]
    end

    test "exports GEMINI_THINKING_LEVEL for low/medium/high :thinking" do
      for level <- ["low", "medium", "high"] do
        env = Gemini.spawn_env(thinking: level)

        assert {"GEMINI_THINKING_LEVEL", ^level} =
                 Enum.find(env, &match?({"GEMINI_THINKING_LEVEL", _}, &1))
      end
    end

    test "clamps above-ladder levels to Gemini's own ceiling instead of dropping them" do
      # #1519: D4/D5 route "max" (and workspaces route "xhigh"). Gemini has no
      # level above "high", and the old whitelist silently emitted NO env var
      # for anything it did not recognise — a Gemini workspace would have LOST
      # its reasoning budget at the top of the scale.
      for level <- ["xhigh", "max"] do
        env = Gemini.spawn_env(thinking: level)

        assert {"GEMINI_THINKING_LEVEL", "high"} in env,
               "expected #{level} to clamp to high, got #{inspect(env)}"
      end
    end

    test "omits GEMINI_THINKING_LEVEL when :thinking is none / nil" do
      refute Enum.any?(
               Gemini.spawn_env(thinking: "none"),
               &match?({"GEMINI_THINKING_LEVEL", _}, &1)
             )

      refute Enum.any?(Gemini.spawn_env([]), &match?({"GEMINI_THINKING_LEVEL", _}, &1))
    end

    test "composes thinking + api key" do
      env = Gemini.spawn_env(api_key: "k", thinking: "high")

      assert {"GEMINI_API_KEY", "k"} in env
      assert {"GOOGLE_GENAI_API_KEY", "k"} in env
      assert {"GEMINI_THINKING_LEVEL", "high"} in env
    end
  end

  describe "splice_prompt/2 — resume (bd-b7e33c)" do
    test "agy branch: translates --resume into --conversation <id> and preserves --print-timeout/--model/--effort" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/agy",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--dangerously-skip-permissions",
        "--model",
        "gemini-3.1-pro",
        "--effort",
        "high",
        "--output-format",
        "stream-json",
        "--print-timeout",
        "300s"
      ]

      assert {:ok, out} =
               Gemini.splice_prompt(argv, ["--resume", "sess-abc", "CONTINUE PROMPT"])

      idx = Enum.find_index(out, &(&1 == "-p"))
      assert Enum.slice(out, idx, 2) == ["-p", "CONTINUE PROMPT"]
      refute "ORIGINAL TASK PROMPT" in out

      assert chunk_after(out, "--conversation") == "sess-abc"
      assert chunk_after(out, "--model") == "gemini-3.1-pro"
      assert chunk_after(out, "--effort") == "high"
      assert chunk_after(out, "--print-timeout") == "300s"
      assert "--dangerously-skip-permissions" in out
      assert "--output-format" in out and "stream-json" in out
    end

    test "upstream gemini branch: --resume is rejected with an explicit error, not a bogus invocation" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/gemini",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--skip-trust",
        "-y",
        "--model",
        "gemini-2.5-pro",
        "--output-format",
        "stream-json"
      ]

      assert {:error, :resume_unsupported} =
               Gemini.splice_prompt(argv, ["--resume", "sess-abc", "CONTINUE PROMPT"])
    end

    test "nudge: swaps only the prompt, leaving every flag (agy or upstream) untouched" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/agy",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--model",
        "gemini-3.1-pro",
        "--output-format",
        "stream-json"
      ]

      assert {:ok, out} = Gemini.splice_prompt(argv, ["nudge prompt"])

      idx = Enum.find_index(out, &(&1 == "-p"))
      assert Enum.slice(out, idx, 2) == ["-p", "nudge prompt"]
      refute "ORIGINAL TASK PROMPT" in out
      refute "--conversation" in out
      assert chunk_after(out, "--model") == "gemini-3.1-pro"
    end

    test "errors when there is no -p slot (custom command / fixture)" do
      assert {:error, :no_print_slot} =
               Gemini.splice_prompt(["sh", "-c", "echo hi; exit 0"], ["nudge"])

      assert {:error, :no_print_slot} =
               Gemini.splice_prompt(["sh", "-c", "echo hi; exit 0"], [
                 "--resume",
                 "sid",
                 "prompt"
               ])
    end
  end

  # bd-7s29yq (T6b): the agy security seam. `Gemini.Security` owns the
  # policy -> agy vocabulary mapping and is unit-tested in
  # `gemini/security_test.exs`; these cover the *wiring* — that the adapter
  # actually emits it.
  describe "agy security wiring (bd-7s29yq)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gemini-sec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      agy = Path.join(tmp, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      old_path = System.get_env("PATH")
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, agy: agy}
    end

    test ":strict emits --sandbox and never --dangerously-skip-permissions", %{agy: agy} do
      policy = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})

      assert {:ok, argv} = Gemini.default_argv("p", security: policy)
      assert ["sh", "-c", _exec, "sh", ^agy, "-p", "p" | rest] = argv
      assert "--sandbox" in rest
      refute "--dangerously-skip-permissions" in rest
    end

    test ":auto emits neither flag — the generated settings carry the posture", %{agy: agy} do
      policy = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :auto}})

      assert {:ok, argv} = Gemini.default_argv("p", security: policy)
      assert ["sh", "-c", _exec, "sh", ^agy, "-p", "p" | rest] = argv
      refute "--sandbox" in rest
      refute "--dangerously-skip-permissions" in rest
    end
  end

  describe "security_enforced?/0 (bd-7s29yq AC3)" do
    test "is false when the isolated agy HOME is switched off — nothing is enforced then" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, false)
      on_exit(fn -> Application.put_env(:arbiter, :worker_isolate_config, prev) end)

      refute Gemini.security_enforced?()
    end

    test "is true only for the agy CLI with isolation on — upstream gemini has no seam" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      tmp = Path.join(System.tmp_dir!(), "gemini-enf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH")

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_isolate_config, prev)
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      gemini = Path.join(tmp, "gemini")
      File.write!(gemini, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini, 0o755)
      System.put_env("PATH", tmp)
      refute Gemini.security_enforced?()

      agy = Path.join(tmp, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      assert Gemini.security_enforced?()
    end
  end

  describe "spawn_env/1 — isolated agy HOME (bd-7s29yq AC2)" do
    test "injects HOME so the operator's ~/.gemini memory, skills and plugins cannot load" do
      base = Path.join(System.tmp_dir!(), "gemini-home-#{System.unique_integer([:positive])}")
      prev_enabled = Application.get_env(:arbiter, :worker_isolate_config)
      prev_root = Application.get_env(:arbiter, :worker_agy_home_root)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_agy_home_root, Path.join(base, "homes"))

      # home_env/1 only fires for the resolved `agy` executable — stub one onto
      # PATH so this test doesn't depend on the host actually having agy installed.
      bin = Path.join(base, "bin")
      File.mkdir_p!(bin)
      agy = Path.join(bin, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      old_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> old_path)

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_isolate_config, prev_enabled)

        if is_nil(prev_root),
          do: Application.delete_env(:arbiter, :worker_agy_home_root),
          else: Application.put_env(:arbiter, :worker_agy_home_root, prev_root)

        System.put_env("PATH", old_path)
        File.rm_rf!(base)
      end)

      env = Gemini.spawn_env(worktree: Path.join(base, "wt"))
      assert {"HOME", home} = Enum.find(env, &match?({"HOME", _}, &1))
      assert home != System.user_home()
      assert File.regular?(Path.join(home, ".gemini/GEMINI.md"))
      assert File.regular?(Path.join(home, ".gemini/antigravity-cli/settings.json"))
    end

    test "injects no HOME when isolation is off (unchanged inherited behaviour)" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, false)
      on_exit(fn -> Application.put_env(:arbiter, :worker_isolate_config, prev) end)

      refute Enum.any?(Gemini.spawn_env(api_key: "k"), &match?({"HOME", _}, &1))
    end
  end

  # bd-481sz7 AC3: the preflight probe must request structured output so its
  # usage_events row carries real token counts (previously it ran `-p ping`
  # with no `--output-format`, so `Arbiter.Agents.Gemini.Stream` had nothing
  # to parse and every agy preflight row landed with zero tokens).
  describe "auth_probe_argv/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-probe-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "requests stream-json structured output for agy", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "ping" | rest] = argv
      assert "--output-format" in rest

      assert Enum.at(rest, Enum.find_index(rest, &(&1 == "--output-format")) + 1) ==
               "stream-json"
    end

    test "requests stream-json structured output for upstream gemini", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "ping" | rest] = argv
      assert "--output-format" in rest
    end

    test "returns {:error, ...} when neither CLI is on PATH" do
      System.put_env("PATH", "/nonexistent-dir-for-test")
      assert {:error, {:executable_not_found, "agy or gemini"}} = Gemini.auth_probe_argv([])
    end
  end

  # bd-svczq4: the pre-flight probe used to be a bare `agy -p ping` — plain-text
  # print mode with no self-timeout, tools on, rooted in the live checkout. It
  # took 102s against a 30s harness watchdog and refused a valid dispatch.
  # bd-481sz7 gave it `--output-format stream-json` (asserted here as a
  # regression guard); what this ticket adds is `--print-timeout`, derived from
  # the harness watchdog so agy yields *first* and a real exit status is always
  # observed instead of agy's own 5-minute default.
  describe "auth_probe_argv/1 (bd-svczq4)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-probe-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    defp stub_exec(tmp, name) do
      path = Path.join(tmp, name)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
      path
    end

    defp flag_value(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        idx -> Enum.at(argv, idx + 1)
      end
    end

    test "agy: asks for a structured result", %{tmp: tmp} do
      agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _script, "sh", ^agy, "-p", "ping" | _rest] = argv
      assert flag_value(argv, "--output-format") == "stream-json"
    end

    test "agy: bounds its own turn strictly inside the harness watchdog", %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv(timeout_ms: 120_000)
      assert value = flag_value(argv, "--print-timeout")
      assert {seconds, "s"} = Integer.parse(value)
      assert seconds > 0
      # Strictly inside: agy must yield and report an exit status before the
      # harness gives up, which is the whole point of the flag.
      assert seconds * 1000 < 120_000
    end

    test "agy: bounds itself even when the caller names no watchdog", %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert value = flag_value(argv, "--print-timeout")
      assert {seconds, "s"} = Integer.parse(value)
      assert seconds > 0
      # Never agy's own 5-minute print-mode default.
      assert seconds < 300
    end

    test "upstream gemini: structured output, but no agy-only --print-timeout", %{tmp: tmp} do
      gemini = stub_exec(tmp, "gemini")

      assert {:ok, argv} = Gemini.auth_probe_argv(timeout_ms: 120_000)
      assert ["sh", "-c", _script, "sh", ^gemini, "-p", "ping" | _rest] = argv
      assert flag_value(argv, "--output-format") == "stream-json"
      refute "--print-timeout" in argv
    end
  end

  describe "async_tool_instruction" do
    test "async_tool_instruction/0 renders reviewer instruction without Claude tools or disproven flags" do
      text = Gemini.async_tool_instruction()

      assert text =~ "manage_task status"
      assert text =~ "RUNNING"
      assert text =~ "your VERDICT"
      assert text =~ "terminates the session and discards the work"
      refute text =~ "Monitor"
      refute text =~ "ScheduleWakeup"
      refute text =~ "TaskOutput"
      assert text =~ "WaitMsBeforeAsync"
      assert text =~ "Blocking"
      refute text =~ "COMMIT correct work BEFORE"
    end

    test "async_tool_instruction/3 respects completion signal, coda, and commit_first option" do
      work_text =
        Gemini.async_tool_instruction("`arb done`", "extra explanation", commit_first: true)

      assert work_text =~ "COMMIT correct work BEFORE"
      assert work_text =~ "before you print `arb done` —\nextra explanation."
      assert work_text =~ "manage_task status"
      assert work_text =~ "RUNNING"
      refute work_text =~ "Monitor"
      refute work_text =~ "ScheduleWakeup"
      assert work_text =~ "WaitMsBeforeAsync"
      assert work_text =~ "Blocking"

      no_commit = Gemini.async_tool_instruction("`arb done`", nil, commit_first: false)
      refute no_commit =~ "COMMIT correct work BEFORE"
      assert no_commit =~ "before you print `arb done`."
    end

    # bd-apq1g6: the spike invoked `"Blocking": true` / `"WaitMsBeforeAsync": 0`
    # verbatim and agy backgrounded the command anyway. The instruction may
    # still tell the worker to pass those arguments, but it must not promise
    # they produce foreground/synchronous execution — that claim is disproven,
    # and a worker that believes it will be surprised by empty inline output.
    test "does not promise that Blocking/WaitMsBeforeAsync produce synchronous execution" do
      for text <- [
            Gemini.async_tool_instruction(),
            Gemini.async_tool_instruction("`arb done`", nil, commit_first: true)
          ] do
        refute text =~ "executes synchronously"
        refute text =~ "returns its output inline"
        refute text =~ ~r/synchronously in the\s+foreground/

        # the corrected framing: flags are set, but backgrounding is expected
        # and the drain is the polling loop.
        assert text =~ "does NOT keep a long"
        assert text =~ "manage_task status"
      end
    end
  end
end
