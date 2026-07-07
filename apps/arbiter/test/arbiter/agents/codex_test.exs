defmodule Arbiter.Agents.CodexTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.SecurityPolicy

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Codex.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"codex\"" do
      assert Codex.provider() == "codex"
    end

    test "done_sentinel/0 matches `arb done` on a word boundary" do
      assert Regex.match?(Codex.done_sentinel(), "all set — arb done")
      refute Regex.match?(Codex.done_sentinel(), "arb doneness")
    end

    test "security_enforced?/0 is false (no per-tool deny list like Claude's)" do
      refute Codex.security_enforced?()
    end

    test "usage_attrs/1 stamps the provider" do
      attrs = Codex.usage_attrs(%{usage: %{tokens_in: 5}})
      assert attrs[:provider] == "codex"
      assert attrs[:tokens_in] == 5
    end
  end

  describe "resolved_model/1" do
    setup do
      Codex.Config.clear()
      on_exit(&Codex.Config.clear/0)
      :ok
    end

    test "uses an explicit :model override verbatim" do
      assert Codex.resolved_model(model: "gpt-5-codex") == "gpt-5-codex"
    end

    test "resolves a :model_tier to a concrete model via the default tier map" do
      assert Codex.resolved_model(model_tier: "premium") == "gpt-5-codex"
      assert Codex.resolved_model(model_tier: "economy") == "gpt-5-codex-mini"
    end

    test "returns nil when nothing is configured (CLI picks its own default)" do
      assert Codex.resolved_model([]) == nil
    end
  end

  describe "default_argv/2 executable resolution" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-codex-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp, old_path: old_path}
    end

    defp stub_codex(tmp) do
      codex = Path.join(tmp, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)
      codex
    end

    test "returns {:error, ...} when `codex` is not on PATH", %{old_path: old_path} do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "codex"}} = Codex.default_argv("hello", [])
      after
        System.put_env("PATH", old_path)
      end
    end

    test "builds a `codex exec --json` invocation wrapped for closed stdin", %{tmp: tmp} do
      codex = stub_codex(tmp)

      assert {:ok, argv} = Codex.default_argv("the prompt", [])
      assert ["sh", "-c", script, "sh", ^codex, "exec" | rest] = argv
      assert script =~ "< /dev/null"
      assert "--json" in rest
      # The prompt is the final positional, delimited by `--` so a prompt that
      # starts with `-` is never parsed as a flag.
      assert List.last(argv) == "the prompt"
      assert "--" in rest
    end

    test ":bypass security mode bypasses approvals and the sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      bypass = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: bypass)
      assert "--dangerously-bypass-approvals-and-sandbox" in argv
      refute "-s" in argv
    end

    test ":strict security mode maps to a read-only sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      strict = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: strict)
      assert chunk_after(argv, "-s") == "read-only"
      refute "--dangerously-bypass-approvals-and-sandbox" in argv
    end

    test ":auto security mode maps to a workspace-write sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      auto = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :auto}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: auto)
      assert chunk_after(argv, "-s") == "workspace-write"
      refute "--dangerously-bypass-approvals-and-sandbox" in argv
    end

    test "passes through `:model` opt as `-m <name>`", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      assert {:ok, argv} = Codex.default_argv("the prompt", model: "gpt-5-codex")
      assert chunk_after(argv, "-m") == "gpt-5-codex"
    end

    test "large prompts are delivered via stdin, not spliced into argv", %{tmp: tmp} do
      codex = stub_codex(tmp)

      big = String.duplicate("x", 200_000)
      assert {:ok, argv} = Codex.default_argv(big, [])
      # The oversize prompt is NOT an argv element (would blow MAX_ARG_STRLEN).
      refute big in argv
      # Instead a temp file is threaded and `-` tells codex to read stdin.
      assert Enum.any?(argv, &(is_binary(&1) and String.contains?(&1, "arb_codex_prompt_")))
      assert ["sh", "-c", script, "sh" | _] = argv
      assert script =~ ~s(< "$f") or script =~ "$f"
      assert ^codex = Enum.find(argv, &(&1 == codex))
    end
  end

  defp chunk_after(list, flag) do
    list
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.at(1)
  end

  describe "spawn_env/1" do
    setup do
      Codex.Config.clear()
      on_exit(&Codex.Config.clear/0)
      :ok
    end

    test "exports OPENAI_API_KEY from `opts[:api_key]`" do
      assert {"OPENAI_API_KEY", "sk-test"} in Codex.spawn_env(api_key: "sk-test")
    end

    test "returns [] when no api key is configured (ambient ChatGPT auth via CODEX_HOME)" do
      assert Codex.spawn_env([]) == []
    end
  end

  describe "auth_probe_argv/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-codex-probe-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      codex = Path.join(tmp, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)
      {:ok, codex: codex}
    end

    test "returns a cheap `codex exec` round-trip", %{codex: codex} do
      assert {:ok, argv} = Codex.auth_probe_argv([])
      assert ["sh", "-c", _script, "sh", ^codex, "exec" | _rest] = argv
    end
  end

  describe "prompt_tmpfile/1 and splice_prompt/2" do
    test "prompt_tmpfile/1 extracts the temp file path for stdin-mode argv" do
      argv = [
        "sh",
        "-c",
        "f=\"$1\"; shift; exec \"$@\" < \"$f\"",
        "sh",
        "/tmp/arb_codex_prompt_12345.txt",
        "/path/to/codex",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--",
        "-"
      ]

      assert Codex.prompt_tmpfile(argv) == "/tmp/arb_codex_prompt_12345.txt"
    end

    test "prompt_tmpfile/1 returns nil for inline-mode argv" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--",
        "some prompt"
      ]

      assert Codex.prompt_tmpfile(argv) == nil
    end

    test "splice_prompt/2 replaces prompt for inline-mode argv (nudge)" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "original prompt"
      ]

      assert {:ok, new_argv} = Codex.splice_prompt(argv, ["nudge prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "--json",
               "--",
               "nudge prompt"
             ]
    end

    test "splice_prompt/2 replaces prompt for stdin-mode argv and switches to inline (nudge)" do
      argv = [
        "sh",
        "-c",
        "f=\"$1\"; shift; exec \"$@\" < \"$f\"",
        "sh",
        "/tmp/arb_codex_prompt_12345.txt",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "-"
      ]

      assert {:ok, new_argv} = Codex.splice_prompt(argv, ["nudge prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "--json",
               "--",
               "nudge prompt"
             ]
    end

    test "splice_prompt/2 rebuilds argv for resume" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "original prompt"
      ]

      assert {:ok, new_argv} =
               Codex.splice_prompt(argv, ["--resume", "sess-123", "continue prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "resume",
               "--json",
               "--",
               "sess-123",
               "continue prompt"
             ]
    end
  end
end
