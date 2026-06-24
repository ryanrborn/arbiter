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

    test "resolves :model_tier to a concrete model via the default tier map", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "premium")
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "standard")
      assert "sonnet" in argv

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "economy")
      assert "haiku" in argv
    end

    test ":model wins over :model_tier when both are set", %{stub: stub} do
      assert {:ok, argv} =
               Claude.default_argv("the prompt", model: "opus", model_tier: "economy")

      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest
      refute "haiku" in argv
    end

    test ":model_tier can be overridden per-workspace via tier_models config" do
      Claude.Config.put_active(%{
        "tier_models" => %{"premium" => "opus-custom"}
      })

      on_exit(fn -> Claude.Config.clear() end)

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "premium")
      assert "opus-custom" in argv
      refute "opus" in argv
    end

    test ":thinking emits --effort for low/medium/high", %{stub: _stub} do
      for level <- ["low", "medium", "high"] do
        {:ok, argv} = Claude.default_argv("the prompt", thinking: level)
        assert "--effort" in argv
        assert level in argv
      end
    end

    test ":thinking 'none' / nil emits no effort flag" do
      {:ok, argv1} = Claude.default_argv("the prompt", thinking: "none")
      refute "--effort" in argv1

      {:ok, argv2} = Claude.default_argv("the prompt", thinking: nil)
      refute "--effort" in argv2
    end

    test ":thinking argv can be overridden per-workspace via thinking_argv config" do
      Claude.Config.put_active(%{
        "thinking_argv" => %{"high" => ["--max-thinking-tokens", "16384"]}
      })

      on_exit(fn -> Claude.Config.clear() end)

      {:ok, argv} = Claude.default_argv("the prompt", thinking: "high")
      assert "--max-thinking-tokens" in argv
      assert "16384" in argv
      refute "--effort" in argv
    end

    test "bakes in the install-default security posture when no :security opt given" do
      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      # safe-by-default: bypass mode (headless-safe) + --settings deny document.
      assert "--dangerously-skip-permissions" in argv
      assert "--settings" in argv
      refute "--permission-mode" in argv

      json = settings_json(argv)
      deny = get_in(json, ["permissions", "deny"])
      assert is_list(deny) and deny != []
      assert Enum.any?(deny, &(&1 =~ "rm -rf"))
    end

    test "honors a threaded :security policy (strict + custom deny)" do
      policy =
        Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "strict", "deny" => ["Bash(docker:*)"]}
        })

      assert {:ok, argv} = Claude.default_argv("the prompt", security: policy)
      assert "--permission-mode" in argv
      assert "default" in argv
      assert "Bash(docker:*)" in settings_json(argv)["permissions"]["deny"]
    end

    test "bypass mode emits --dangerously-skip-permissions with --settings deny list" do
      policy =
        Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "bypass"}
        })

      assert {:ok, argv} = Claude.default_argv("the prompt", security: policy)
      assert "--dangerously-skip-permissions" in argv
      assert "--settings" in argv
      refute "--permission-mode" in argv
    end
  end

  # Pull the JSON document out of the `--settings <json>` argv pair.
  defp settings_json(argv) do
    idx = Enum.find_index(argv, &(&1 == "--settings"))
    argv |> Enum.at(idx + 1) |> Jason.decode!()
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

    test "exports `ANTHROPIC_BASE_URL` from `opts[:anthropic_base_url]` (proxy wiring)" do
      assert Claude.spawn_env(anthropic_base_url: "http://127.0.0.1:4848/proxy/anthropic/ws-1") ==
               [{"ANTHROPIC_BASE_URL", "http://127.0.0.1:4848/proxy/anthropic/ws-1"}]
    end

    test "composes ANTHROPIC_BASE_URL after the API key" do
      assert Claude.spawn_env(api_key: "k", anthropic_base_url: "http://localhost/p") == [
               {"ANTHROPIC_API_KEY", "k"},
               {"ANTHROPIC_BASE_URL", "http://localhost/p"}
             ]
    end

    test "omits ANTHROPIC_BASE_URL when the opt is absent or blank" do
      assert Claude.spawn_env(anthropic_base_url: "") == []
      assert Claude.spawn_env([]) == []
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
