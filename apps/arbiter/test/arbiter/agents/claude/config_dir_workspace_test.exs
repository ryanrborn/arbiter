defmodule Arbiter.Agents.Claude.ConfigDirWorkspaceTest do
  @moduledoc """
  bd-bw3466: the credential-seeding gate against a *persisted* workspace.

  `config_dir_test.exs` covers the resolution rules with bare structs; this
  file covers the two things that need a real row — resolving a workspace by
  **id**, and (with the flag off) the install-wide fallback (source 3 of
  `ConfigDir.oauth_token/1`) that the workspace-less call sites
  (`Arbiter.Agents.CredentialWatchdog`, `workflows/code_review/checks.ex`)
  rely on. Per the operator's ruling on PR #1947 (bd-cblemv round 2), this
  flag-off chain is kept verbatim rather than deleted — an unmigrated install
  needs it for those workspace-less spawns.

  The load-bearing property here is the **lockstep invariant**: seeding is
  suppressed exactly when a token is injected, and `env/1` emits an explicit
  `{"CLAUDE_CODE_OAUTH_TOKEN", false}` unset rather than merely omitting the
  pair when nothing is configured, so a spawn that carries no token also
  carries an explicit instruction to unset any value it would otherwise
  inherit from the arbiter server's own process environment. Breaking either
  half leaves the fleet-wide watchdog probe with an emptied config dir and no
  token (a guaranteed 401 that marks the adapter expired and stops every
  dispatch), or leaves a suppressed-seeding spawn quietly authenticated as
  the operator via an inherited server token (bd-6umoh9's dual-refresher
  race). `"env/1 lockstep: seeding suppressed iff a token pair is injected"`
  below asserts the property directly across every shape this file covers.
  """
  # async: false — toggles Application/System env that other tests read.
  use Arbiter.DataCase, async: false

  # The ambiguous-token case (install_oauth_token/0) logs a warning by
  # design; capture it so the run stays readable (logs still surface on
  # failure).
  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount

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

  describe "install-wide seeding gate for workspace-less call sites (flag off)" do
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

    test "a workspace-less spawn carries the unambiguous install-wide token", %{target: target} do
      _ = token_workspace()
      _ = token_workspace()

      # Both workspaces define the *same* token, so there is exactly one value
      # a workspace-less spawn could carry — carry it. Suppressing the seed
      # without injecting anything would leave the CredentialWatchdog probe
      # with no credentials at all.
      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "workspaces that disagree leave a workspace-less spawn at pre-fix behaviour", %{
      source: source,
      target: target
    } do
      _ = token_workspace()

      _ =
        workspace_with_env(%{
          "CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "other", "secret" => true}
        })

      # Two distinct values: we refuse to guess, so no token is injected — and
      # the gate must stand down with it rather than emptying the config dir.
      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]

      assert {:ok, ^target} = ConfigDir.ensure()

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end

    test "the workspace-bearing spawn is unaffected by an ambiguous install", %{target: target} do
      ws = token_workspace()

      _ =
        workspace_with_env(%{
          "CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "other", "secret" => true}
        })

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "a workspace-less spawn plus one install-wide token gives that token", %{
      target: target
    } do
      ws = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure()
      refute File.exists?(Path.join(target, ".credentials.json"))

      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]

      assert ConfigDir.oauth_token(ws.id) == "ws-oauth-token"
    end

    # The invariant the first cut of bd-bw3466 broke: a spawn whose
    # `.credentials.json` we suppress must always be handed a token, or it has
    # no credentials at all. The CredentialWatchdog probes with no workspace,
    # 401s, and marks the adapter expired — stopping every dispatch.
    test "ensure/0 suppressing the seed implies env/0 carries a token", %{target: target} do
      for build <- [
            fn -> :none end,
            &token_workspace/0,
            fn -> {token_workspace(), token_workspace()} end
          ] do
        _ = build.()

        assert {:ok, ^target} = ConfigDir.ensure()
        suppressed? = not File.exists?(Path.join(target, ".credentials.json"))

        injected? =
          case List.keyfind(ConfigDir.env(), "CLAUDE_CODE_OAUTH_TOKEN", 0) do
            {_, token} when is_binary(token) -> true
            _ -> false
          end

        assert suppressed? == injected?,
               "seed suppressed?=#{suppressed?} but token injected?=#{injected?}"
      end
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

  describe "env/1 lockstep: seeding suppressed iff a token pair is injected" do
    defp account(opts \\ []) do
      {:ok, acct} =
        Ash.create(ProviderAccount, %{
          provider: :claude,
          slug: "acct-#{System.unique_integer([:positive])}",
          enabled: Keyword.get(opts, :enabled, true)
        })

      acct
    end

    defp credential(account, secret) do
      {:ok, cred} =
        Ash.create(ProviderCredential, %{
          provider_account_id: account.id,
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
          active: true,
          secret: secret
        })

      cred
    end

    defp link_account(ws, account) do
      {:ok, link} =
        Ash.create(WorkspaceProviderAccount, %{
          workspace_id: ws.id,
          provider: account.provider,
          provider_account_id: account.id
        })

      link
    end

    # The property under test: exactly one of (a real token pair, seeding
    # suppressed) or (an explicit `{..., false}` unset pair, seeding
    # happens) holds for any workspace/flag shape. Breaking it either
    # 401s the fleet-wide watchdog (gate fires with nothing injected) or
    # quietly re-opens bd-6umoh9 (gate stands down while a server-process
    # token still reaches the child via Port.open's ambient inheritance).
    defp assert_lockstep(workspace, target) do
      env = ConfigDir.env(workspace)
      token_pair = List.keyfind(env, "CLAUDE_CODE_OAUTH_TOKEN", 0)

      assert {:ok, ^target} = ConfigDir.ensure(workspace)
      seeded? = File.exists?(Path.join(target, ".credentials.json"))

      case token_pair do
        {"CLAUDE_CODE_OAUTH_TOKEN", token} when is_binary(token) ->
          refute seeded?, "expected seeding suppressed when a real token is injected"

        {"CLAUDE_CODE_OAUTH_TOKEN", false} ->
          assert seeded?, "expected seeding once the token pair is an explicit unset"
      end
    end

    test "flag off, no workspace, no token anywhere", %{target: target} do
      assert_lockstep(nil, target)
    end

    test "flag off, workspace with its own token", %{target: target} do
      assert_lockstep(token_workspace(), target)
    end

    test "flag off, workspace with no token, server env set", %{target: target} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      ws = workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug", "secret" => false}})

      assert_lockstep(ws, target)
    end

    test "flag on, workspace joined to an account credential", %{target: target} do
      Application.put_env(:arbiter, :provider_accounts_enabled, true)
      ws = workspace_with_env(%{})
      acct = account()
      credential(acct, "account-token")
      link_account(ws, acct)

      assert_lockstep(ws, target)
    end

    test "flag on, no workspace, one unambiguous install-wide account credential", %{
      target: target
    } do
      Application.put_env(:arbiter, :provider_accounts_enabled, true)
      acct = account()
      credential(acct, "install-token")
      link_account(workspace_with_env(%{}), acct)

      assert_lockstep(nil, target)
    end

    test "flag on, no workspace, no account anywhere", %{target: target} do
      Application.put_env(:arbiter, :provider_accounts_enabled, true)

      assert_lockstep(nil, target)
    end
  end
end
