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
end
