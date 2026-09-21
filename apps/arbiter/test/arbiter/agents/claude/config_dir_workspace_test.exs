defmodule Arbiter.Agents.Claude.ConfigDirWorkspaceTest do
  @moduledoc """
  bd-bw3466: the credential-seeding gate against a *persisted* workspace.

  `config_dir_test.exs` covers the resolution rules with bare structs; this
  file covers resolving a workspace by **id**, and (with the flag off) the
  workspace-less call sites (`Arbiter.Agents.CredentialWatchdog`,
  `workflows/code_review/checks.ex`) that used to rely on the install-wide
  fallback P4 (bd-cblemv) deleted — they now carry no token at all rather than
  guessing one from workspace agreement.

  The load-bearing property here is the **lockstep invariant**: seeding is
  suppressed exactly when a token is injected. Breaking it leaves the
  fleet-wide watchdog probe with an emptied config dir and no token, which
  401s, marks the adapter expired and stops every dispatch.
  """
  # async: false — toggles Application/System env that other tests read.
  use Arbiter.DataCase, async: false

  # The ambiguous-token case logs a warning by design; capture it so the run
  # stays readable (logs still surface on failure).
  @moduletag :capture_log

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
    prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    # `worker_env` as the credential source is the pre-P3 behaviour these
    # tests pin (acceptance 2 of bd-aiodva); the provider-account read that
    # replaces it behind `:provider_accounts_enabled` is covered by
    # `arbiter/accounts/read_flip_test.exs`. Pin the flag off so the
    # `ARBITER_PROVIDER_ACCOUNTS=1` matrix leg does not reinterpret them.
    Application.put_env(:arbiter, :provider_accounts_enabled, false)

    on_exit(fn ->
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:worker_config_dir, prev_dir)
      restore_app(:provider_accounts_enabled, prev_flag)
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

    test "an unknown workspace id carries no token rather than raising", %{
      source: source,
      target: target
    } do
      assert ConfigDir.oauth_token("no-such-workspace") == nil
      assert {:ok, ^target} = ConfigDir.ensure("no-such-workspace")

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end
  end

  describe "workspace-less call sites, flag off (P4, bd-cblemv)" do
    # P4 deletes the install-wide-unambiguous fallback (`any_workspace_oauth_token?/0`,
    # `workspace_oauth_tokens/0`, `install_oauth_token/0`): the account join is
    # the only workspace-less source now, and with `:provider_accounts_enabled`
    # off there is no account to join against, so a workspace-less spawn
    # carries no token regardless of what any workspace defines — and keeps
    # seeding `.credentials.json` as its only path to credentials.
    test "ensure/0 keeps seeding even once a workspace defines the token", %{
      target: target
    } do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.exists?(Path.join(target, ".credentials.json"))

      _ = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.exists?(Path.join(target, ".credentials.json"))
    end

    test "a workspace-less spawn carries no token even when every workspace agrees", %{
      target: target
    } do
      _ = token_workspace()
      _ = token_workspace()

      assert ConfigDir.env() == [{"CLAUDE_CONFIG_DIR", target}]
    end

    test "the workspace-bearing spawn is unaffected by workspace-less calls carrying no token",
         %{target: target} do
      ws = token_workspace()

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "seeding still happens when no workspace defines a token", %{
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
