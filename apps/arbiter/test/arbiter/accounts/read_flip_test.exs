defmodule Arbiter.Accounts.ReadFlipTest do
  @moduledoc """
  P3 (bd-aiodva): the read-path flip behind `:provider_accounts_enabled`
  (`docs/provider-account-design.md` §5 rows 15–18, §7.5 "Release N+1").

  Three functions change *where* a provider credential comes from — the
  account's active `provider_credentials` row, joined through
  `workspace_provider_accounts` — without changing the shape they hand a
  spawn:

    * `Arbiter.Agents.Claude.ConfigDir.oauth_token/1`
    * `Arbiter.Agents.Claude.ConfigDir.env/1`
    * `Arbiter.Worker.WorkerEnv.resolve/1`

  Each has a test here with the flag **on**, a regression test with it
  **off** (the production default — behaviour must be byte-for-byte what it
  was pre-P3), and the loud-failure case: a workspace whose blob still
  carries a credential but which has no `workspace_provider_accounts` row
  must raise rather than dispatch a worker with no token.
  """
  # async: false — toggles Application env other tests read.
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.MissingCredentialError
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv

  @oauth_var "CLAUDE_CODE_OAUTH_TOKEN"

  setup do
    # The config dir itself is out of scope here: with isolation off, `env/1`
    # emits only the token pair, which is the part P3 moves.
    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)
    prev_server_token = System.get_env(@oauth_var)

    Application.put_env(:arbiter, :worker_isolate_config, false)
    System.delete_env(@oauth_var)

    on_exit(fn ->
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:provider_accounts_enabled, prev_flag)
      restore_sys(@oauth_var, prev_server_token)
    end)

    :ok
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)
  defp restore_sys(name, nil), do: System.delete_env(name)
  defp restore_sys(name, val), do: System.put_env(name, val)

  defp flag(value), do: Application.put_env(:arbiter, :provider_accounts_enabled, value)

  defp uniq, do: System.unique_integer([:positive])

  defp workspace_with_env(worker_env) do
    {:ok, ws} = Ash.create(Workspace, %{name: "p3-#{uniq()}", worker_env: worker_env})
    ws
  end

  defp token_workspace(token \\ "ws-blob-token") do
    workspace_with_env(%{@oauth_var => %{"value" => token, "secret" => true}})
  end

  defp task_in(ws) do
    {:ok, task} = Ash.create(Issue, %{title: "p3", workspace_id: ws.id})
    task
  end

  defp account(opts) do
    provider = Keyword.get(opts, :provider, :claude)

    {:ok, account} =
      Ash.create(ProviderAccount, %{
        provider: provider,
        slug: Keyword.get(opts, :slug, "acct-#{uniq()}"),
        enabled: Keyword.get(opts, :enabled, true)
      })

    account
  end

  defp credential(account, secret, opts \\ []) do
    {:ok, cred} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: Keyword.get(opts, :kind, :oauth_token),
        env_var: Keyword.get(opts, :env_var, @oauth_var),
        fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
        active: Keyword.get(opts, :active, true),
        secret: secret
      })

    cred
  end

  defp link(ws, account) do
    {:ok, link} =
      Ash.create(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: account.provider,
        provider_account_id: account.id
      })

    link
  end

  # A workspace pointed at an account holding `secret` under `env_var`.
  defp workspace_on_account(ws, secret, opts \\ []) do
    acct = account(opts)
    credential(acct, secret, opts)
    link(ws, acct)
    acct
  end

  describe "ConfigDir.oauth_token/1 with the flag on (acceptance 1)" do
    test "sources the token from the account, not the workspace blob" do
      ws = token_workspace("stale-blob-token")
      workspace_on_account(ws, "account-token")

      flag(true)

      assert ConfigDir.oauth_token(ws) == "account-token"
      assert ConfigDir.oauth_token(ws.id) == "account-token"
    end

    test "ignores a retired credential and reads the active one" do
      ws = token_workspace()
      acct = account([])
      credential(acct, "rotated-out", active: false)
      credential(acct, "current-token")
      link(ws, acct)

      flag(true)

      assert ConfigDir.oauth_token(ws) == "current-token"
    end

    test "a workspace-less spawn reads the unambiguous install-wide account token" do
      ws = token_workspace()
      workspace_on_account(ws, "install-wide-account-token")

      flag(true)

      assert ConfigDir.oauth_token() == "install-wide-account-token"
    end
  end

  describe "ConfigDir.env/1 with the flag on (acceptance 1)" do
    test "projects the account's credential into the spawn env pairs" do
      ws = token_workspace("stale-blob-token")
      workspace_on_account(ws, "account-token")

      flag(true)

      assert ConfigDir.env(ws) == [{@oauth_var, "account-token"}]
      assert ConfigDir.env(ws.id) == [{@oauth_var, "account-token"}]
    end
  end

  describe "WorkerEnv.resolve/1 with the flag on (acceptance 1)" do
    test "non-credential vars come from the workspace, the credential from the account" do
      ws =
        workspace_with_env(%{
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false},
          @oauth_var => %{"value" => "stale-blob-token", "secret" => true}
        })

      workspace_on_account(ws, "account-token")
      task = task_in(ws)

      flag(false)
      {pairs, secrets} = WorkerEnv.resolve(task.id)

      assert Enum.sort(pairs) == [{@oauth_var, "stale-blob-token"}, {"LOG_LEVEL", "debug"}]
      refute "account-token" in secrets

      flag(true)

      {pairs, secrets} = WorkerEnv.resolve(task.id)

      assert Enum.sort(pairs) == [{@oauth_var, "account-token"}, {"LOG_LEVEL", "debug"}]
      # The account's secret is redacted from worker output like any other.
      assert "account-token" in secrets
      refute "stale-blob-token" in secrets
    end

    test "carries every provider's credential, not just Claude's" do
      ws = workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug", "secret" => false}})

      workspace_on_account(ws, "claude-token")

      workspace_on_account(ws, "sk-openai",
        provider: :codex,
        env_var: "OPENAI_API_KEY",
        kind: :api_key
      )

      task = task_in(ws)

      flag(true)

      {pairs, _secrets} = WorkerEnv.resolve(task.id)

      assert Enum.sort(pairs) == [
               {@oauth_var, "claude-token"},
               {"LOG_LEVEL", "debug"},
               {"OPENAI_API_KEY", "sk-openai"}
             ]
    end
  end

  describe "the production spawn path" do
    test "Claude.spawn_env/1 carries the account's token, not the blob's" do
      ws = token_workspace("stale-blob-token")
      workspace_on_account(ws, "account-token")

      flag(true)

      # `Arbiter.Agents.Claude.spawn_env/1` is what actually builds a worker
      # spawn's environment (`claude.ex:258` → `ConfigDir.env/1`), so this is
      # the flip observed where it matters rather than one function down.
      assert Claude.spawn_env(workspace: ws) == [{@oauth_var, "account-token"}]
    end
  end

  describe "with the flag off (acceptance 2 — pre-P3 behaviour, byte for byte)" do
    test "all three functions ignore the account tables entirely" do
      ws = token_workspace("blob-token")
      workspace_on_account(ws, "account-token")
      task = task_in(ws)

      flag(false)

      assert ConfigDir.oauth_token(ws) == "blob-token"
      assert ConfigDir.oauth_token(ws.id) == "blob-token"
      assert ConfigDir.env(ws) == [{@oauth_var, "blob-token"}]

      {pairs, secrets} = WorkerEnv.resolve(task.id)
      assert pairs == [{@oauth_var, "blob-token"}]
      assert secrets == ["blob-token"]
    end

    test "the workspace-less install-wide fallback still reads workspaces" do
      ws = token_workspace("blob-token")
      workspace_on_account(ws, "account-token")

      flag(false)

      assert ConfigDir.oauth_token() == "blob-token"
    end
  end

  describe "no workspace_provider_accounts row with the flag on (acceptance 3)" do
    test "ConfigDir.oauth_token/1 raises rather than dispatching a nil token" do
      ws = token_workspace("blob-token")

      flag(true)

      assert_raise MissingCredentialError, ~r/#{ws.id}/, fn -> ConfigDir.oauth_token(ws) end
      assert_raise MissingCredentialError, fn -> ConfigDir.oauth_token(ws.id) end
    end

    test "ConfigDir.env/1 raises rather than emitting env pairs with no credential" do
      ws = token_workspace("blob-token")

      flag(true)

      assert_raise MissingCredentialError, fn -> ConfigDir.env(ws) end
    end

    test "WorkerEnv.resolve/1 raises rather than silently dropping the credential" do
      ws = token_workspace("blob-token")
      task = task_in(ws)

      flag(true)

      assert_raise MissingCredentialError, ~r/#{@oauth_var}/, fn -> WorkerEnv.resolve(task.id) end
    end

    test "an account that covers only one provider still raises for the uncovered one" do
      ws =
        workspace_with_env(%{
          @oauth_var => %{"value" => "blob-token", "secret" => true},
          "OPENAI_API_KEY" => %{"value" => "sk-openai", "secret" => true}
        })

      workspace_on_account(ws, "account-token")
      task = task_in(ws)

      flag(true)

      assert_raise MissingCredentialError, ~r/OPENAI_API_KEY/, fn ->
        WorkerEnv.resolve(task.id)
      end
    end

    test "a disabled account is not a credential source" do
      ws = token_workspace("blob-token")
      workspace_on_account(ws, "account-token", enabled: false)

      flag(true)

      assert_raise MissingCredentialError, fn -> ConfigDir.oauth_token(ws) end
    end
  end

  describe "a workspace with no credential at all (the quiet case)" do
    test "stays quiet with the flag on — there is nothing to lose" do
      ws = workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug", "secret" => false}})
      task = task_in(ws)

      flag(true)

      assert ConfigDir.oauth_token(ws) == nil
      assert ConfigDir.env(ws) == []
      assert WorkerEnv.resolve(task.id) == {[{"LOG_LEVEL", "debug"}], []}
    end

    test "an unknown task id and an unknown workspace id stay quiet with the flag on" do
      flag(true)

      assert WorkerEnv.resolve("does-not-exist") == {[], []}
      assert ConfigDir.oauth_token("00000000-0000-0000-0000-000000000000") == nil
    end
  end
end
