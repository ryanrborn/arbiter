defmodule Arbiter.Agents.ClaudeTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Claude

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Claude.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"claude\"" do
      assert Claude.provider() == "claude"
    end

    test "done_sentinel/0 matches `arb done`" do
      assert Regex.match?(Claude.done_sentinel(), "I am done — arb done")
      refute Regex.match?(Claude.done_sentinel(), "arb doneness")
    end
  end

  describe "default_argv/2 with a stubbed claude binary" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-claude-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      stub = Path.join(tmp, "claude")
      File.write!(stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(stub, 0o755)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{tmp}:#{old_path}")

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, stub: stub, old_path: old_path, tmp: tmp}
    end

    test "returns {:error, ...} when the `claude` CLI isn't on PATH", %{
      old_path: old_path,
      tmp: tmp
    } do
      # Inside this test, drop our stub dir from PATH so resolution fails,
      # then restore the stubbed PATH so subsequent tests see the stub.
      stubbed_path = "#{tmp}:#{old_path}"
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "claude"}} = Claude.default_argv("hello", [])
      after
        System.put_env("PATH", stubbed_path)
      end
    end

    test "produces a streaming-json argv wrapped in sh", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--output-format" in rest
      assert "stream-json" in rest
      assert "--verbose" in rest
      refute "--model" in rest
    end

    test "passes through `:model` opt as `--model <name>`", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", model: "opus")
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest
    end

    test "falls back to the active per-process model when no opt given", %{stub: stub} do
      Claude.Config.put_active(%{"model" => "haiku"})

      on_exit(fn -> Claude.Config.clear() end)

      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "haiku" in rest
    end
  end

  describe "spawn_env/1 (key rotation)" do
    setup do
      on_exit(fn -> Claude.Config.clear() end)
      :ok
    end

    test "returns [] when no api_key is configured (CLI uses ambient auth)" do
      assert Claude.spawn_env([]) == []
    end

    test "exports `ANTHROPIC_API_KEY` from `opts[:api_key]`" do
      assert Claude.spawn_env(api_key: "literal-token") ==
               [{"ANTHROPIC_API_KEY", "literal-token"}]
    end

    test "rotates through `api_keys` from active config" do
      System.put_env("ARB_TEST_KEY_A", "key-a")
      System.put_env("ARB_TEST_KEY_B", "key-b")

      on_exit(fn ->
        System.delete_env("ARB_TEST_KEY_A")
        System.delete_env("ARB_TEST_KEY_B")
      end)

      Claude.Config.put_active(%{
        "api_keys" => ["env:ARB_TEST_KEY_A", "env:ARB_TEST_KEY_B"]
      })

      assert Claude.spawn_env([]) == [{"ANTHROPIC_API_KEY", "key-a"}]
      assert Claude.spawn_env([]) == [{"ANTHROPIC_API_KEY", "key-b"}]
      # Wraps back to the first key on the next call.
      assert Claude.spawn_env([]) == [{"ANTHROPIC_API_KEY", "key-a"}]
    end

    test "prepends an isolated CLAUDE_CONFIG_DIR when config isolation is enabled" do
      target =
        Path.join(System.tmp_dir!(), "arbiter-spawnenv-iso-#{System.unique_integer([:positive])}")

      prev_isolate = Application.get_env(:arbiter, :acolyte_isolate_config)
      prev_dir = Application.get_env(:arbiter, :acolyte_config_dir)
      Application.put_env(:arbiter, :acolyte_isolate_config, true)
      Application.put_env(:arbiter, :acolyte_config_dir, target)

      on_exit(fn ->
        put_or_delete(:acolyte_isolate_config, prev_isolate)
        put_or_delete(:acolyte_config_dir, prev_dir)
        File.rm_rf!(target)
      end)

      # Config-dir isolation comes first; the API key composes on top.
      assert Claude.spawn_env(api_key: "literal-token") == [
               {"CLAUDE_CONFIG_DIR", target},
               {"ANTHROPIC_API_KEY", "literal-token"}
             ]
    end
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:arbiter, key)
  defp put_or_delete(key, val), do: Application.put_env(:arbiter, key, val)

  describe "usage_attrs/1" do
    test "returns an empty-ish map tagged with the provider when no usage was absorbed" do
      session = Claude.init_session([])
      attrs = Claude.usage_attrs(session)
      assert attrs.provider == "claude"
    end
  end
end
