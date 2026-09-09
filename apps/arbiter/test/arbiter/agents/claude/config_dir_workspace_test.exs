defmodule Arbiter.Agents.Claude.ConfigDirWorkspaceTest do
  @moduledoc """
  bd-bw3466: the credential-seeding gate against a *persisted* workspace.

  `config_dir_test.exs` covers the resolution rules with bare structs; this
  file covers the two things that need a real row — resolving a workspace by
  **id**, and the install-wide `any_workspace_oauth_token?/0` fallback the
  workspace-less call sites (`quota/refresh_probe.ex`,
  `workflows/code_review/checks.ex`) rely on so they can't re-seed the
  operator's `.credentials.json` behind a token-bearing workspace's back.
  """
  # async: false — toggles Application/System env that other tests read.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Tasks.Workspace

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-configdir-ws-test-#{uniq}")
    source = Path.join(base, "source")
    target = Path.join(base, "worker")
    File.mkdir_p!(source)
    File.write!(Path.join(source, ".credentials.json"), ~s({"token":"operator"}))

    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_dir = Application.get_env(:arbiter, :worker_config_dir)
    prev_src = System.get_env("CLAUDE_CONFIG_DIR")
    prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    on_exit(fn ->
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:worker_config_dir, prev_dir)
      restore_sys("CLAUDE_CONFIG_DIR", prev_src)
      restore_sys("CLAUDE_CODE_OAUTH_TOKEN", prev_token)
      File.rm_rf!(base)
    end)

    {:ok, source: source, target: target}
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)
  defp restore_sys(name, nil), do: System.delete_env(name)
  defp restore_sys(name, val), do: System.put_env(name, val)

  defp workspace_with_env(worker_env) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cfgdir-#{System.unique_integer([:positive])}",
        worker_env: worker_env
      })

    ws
  end

  defp token_workspace do
    workspace_with_env(%{
      "CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "ws-oauth-token", "secret" => true}
    })
  end

  describe "resolving a workspace by id" do
    test "env/1 accepts a workspace id and injects that workspace's token", %{target: target} do
      ws = token_workspace()

      assert ConfigDir.env(ws.id) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "ensure/1 with a workspace id skips seeding .credentials.json", %{target: target} do
      ws = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure(ws.id)
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "an unknown workspace id degrades to the server env rather than raising", %{
      source: source,
      target: target
    } do
      assert ConfigDir.oauth_token("no-such-workspace") == nil
      assert {:ok, ^target} = ConfigDir.ensure("no-such-workspace")

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end
  end

  describe "install-wide seeding gate for workspace-less call sites" do
    test "any_workspace_oauth_token?/0 reflects whether some workspace defines the token" do
      refute ConfigDir.any_workspace_oauth_token?()
      _ = token_workspace()
      assert ConfigDir.any_workspace_oauth_token?()
    end

    test "ensure/0 does not re-seed credentials once a workspace defines the token", %{
      target: target
    } do
      # A workspace-less spawn seeds today...
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.exists?(Path.join(target, ".credentials.json"))

      # ...and must stop, and clean up, once any workspace holds a token —
      # the shared config dir is install-wide, so the gate must be too.
      _ = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure()
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "a workspace-less spawn still gets no token injected", %{target: target} do
      _ = token_workspace()

      # Seeding is suppressed install-wide, but we never *guess* which
      # workspace's token a workspace-less spawn should carry.
      assert ConfigDir.env() == [{"CLAUDE_CONFIG_DIR", target}]
    end

    test "seeding still happens when no workspace and no server env defines a token", %{
      source: source,
      target: target
    } do
      _ = workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug", "secret" => false}})

      assert {:ok, ^target} = ConfigDir.ensure()

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end
  end
end
