defmodule ArbiterWeb.ProvidersLiveTest do
  @moduledoc """
  `/providers` (bd-cb86s4): provider accounts with their pools, concurrency,
  credential health and 30-day cost — and, with `:provider_accounts_enabled`
  on, create / add-or-rotate credential / attach / detach.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  require Ash.Query

  @secret "sk-ant-oat01-do-not-echo-me-4f9c"

  setup do
    prev = Application.get_env(:arbiter, :provider_accounts_enabled)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:arbiter, :provider_accounts_enabled),
        else: Application.put_env(:arbiter, :provider_accounts_enabled, prev)
    end)

    :ok
  end

  defp enable!(on?), do: Application.put_env(:arbiter, :provider_accounts_enabled, on?)

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name, prefix: "pv"})

  defp account!(provider, slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

  defp event!(account, attrs) do
    Ash.create!(
      Event,
      Map.merge(
        %{
          task_id: "bd-pv-#{System.unique_integer([:positive])}",
          source: :task,
          repo: "arbiter",
          workspace_id: "ws-pv",
          step: :work,
          provider_account_id: account.id,
          occurred_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp active_credentials(account) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account.id and active == true)
    |> Ash.read!()
  end

  defp links(account) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account.id)
    |> Ash.read!()
  end

  describe "the account list" do
    setup do
      enable!(true)
      :ok
    end

    test "is linked from the nav", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers")
      assert has_element?(view, ~s(a[href="/providers"]))
    end

    test "shows one row per account: provider icon, name and attached workspaces", %{conn: conn} do
      ws = workspace!("pv-attached")
      account = account!(:claude, "pv-main", %{label: "Main Max plan"})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live(conn, ~p"/providers")

      assert has_element?(view, "#account-#{account.id}")
      assert has_element?(view, "#account-#{account.id}-provider svg[aria-label=Claude]")
      assert has_element?(view, "#account-#{account.id}-name", "Main Max plan")
      assert has_element?(view, "#account-#{account.id}-ws-#{ws.id}", "pv-attached")
    end

    test "shows each pool's utilization against the paced gate's pace", %{conn: conn} do
      account = account!(:claude, "pv-quota")

      Ash.create!(
        AnthropicQuota,
        %{
          provider_account_id: account.id,
          provider: "claude",
          captured_at: DateTime.utc_now(),
          utilization_5h: 0.9,
          # 1h left of a 5h window: 80% elapsed.
          reset_5h_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          utilization_7d: 0.06,
          reset_7d_at: DateTime.add(DateTime.utc_now(), 6 * 86_400, :second)
        },
        action: :record_oauth_snapshot
      )

      {:ok, view, _html} = live(conn, ~p"/providers")

      assert has_element?(view, "#account-#{account.id}-quota [data-quota-bar=claude]")
      assert has_element?(view, "#account-#{account.id}-pace-5h", "90% used")
      assert has_element?(view, "#account-#{account.id}-pace-5h", "80% pace")
      assert has_element?(view, "#account-#{account.id}-pace-5h[data-pace-verdict=holding]")
      assert has_element?(view, "#account-#{account.id}-pace-7d[data-pace-verdict=ok]")
    end

    test "an account with no quota snapshot says so rather than drawing empty bars", %{conn: conn} do
      account = account!(:codex, "pv-noquota")
      {:ok, view, _html} = live(conn, ~p"/providers")
      assert has_element?(view, "#account-#{account.id}-quota", "No quota snapshot")
    end

    test "shows the concurrency cap and live count", %{conn: conn} do
      capped = account!(:claude, "pv-capped", %{max_concurrent: 4})
      uncapped = account!(:claude, "pv-uncapped")

      {:ok, view, _html} = live(conn, ~p"/providers")

      assert has_element?(view, "#account-#{capped.id}-concurrency", "0 / 4")
      assert has_element?(view, "#account-#{uncapped.id}-concurrency", "no cap")
    end

    test "shows credential health", %{conn: conn} do
      bare = account!(:claude, "pv-bare")
      credentialed = account!(:claude, "pv-credentialed")

      {:ok, _} =
        Accounts.rotate_credential(credentialed.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: @secret
        })

      {:ok, view, html} = live(conn, ~p"/providers")

      assert has_element?(view, "#account-#{bare.id}-health[data-health=no_credential]")
      assert has_element?(view, "#account-#{credentialed.id}-health[data-health=ok]")
      assert has_element?(view, "#account-#{credentialed.id}-credentials", "CLAUDE_CODE_OAUTH_TOKEN")
      assert has_element?(view, "#account-#{credentialed.id}-last-probe", "never")
      refute html =~ @secret
    end

    test "shows 30-day cost, and n/a for an unpriced provider", %{conn: conn} do
      priced = account!(:claude, "pv-priced")
      unpriced = account!(:antigravity, "pv-agy")
      event!(priced, %{provider: "claude", cost_usd: 1.5, tokens_in: 1000, tokens_out: 500})
      event!(unpriced, %{provider: "gemini", cost_usd: nil, tokens_in: 10, tokens_out: 5})

      {:ok, view, _html} = live(conn, ~p"/providers")

      assert has_element?(view, "#account-#{priced.id}-cost", "$1.50")
      assert has_element?(view, "#account-#{unpriced.id}-cost", "n/a")
      refute has_element?(view, "#account-#{unpriced.id}-cost", "$")
    end

    test "an empty install shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers")
      assert has_element?(view, "#providers-empty")
    end
  end

  describe "create an account" do
    setup do
      enable!(true)
      :ok
    end

    test "creates the account and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/providers")

      view |> element("#new-account-button") |> render_click()

      view
      |> form("#account-form",
        account: %{provider: "codex", slug: "pv-new", label: "New one", max_concurrent: "3"}
      )
      |> render_submit()

      assert {:ok, account} = Accounts.get_account("codex:pv-new")
      assert account.label == "New one"
      assert account.max_concurrent == 3
      assert has_element?(view, "#account-#{account.id}")
      refute has_element?(view, "#account-form")
    end

    test "a duplicate slug keeps the form open with the error", %{conn: conn} do
      account!(:claude, "pv-dupe")
      {:ok, view, _html} = live(conn, ~p"/providers")

      view |> element("#new-account-button") |> render_click()

      view
      |> form("#account-form", account: %{provider: "claude", slug: "pv-dupe"})
      |> render_submit()

      assert has_element?(view, "#account-form")
      assert has_element?(view, "#account-form-error")
    end
  end

  describe "add or rotate a credential" do
    setup do
      enable!(true)
      :ok
    end

    test "posts the secret to the encrypted store and never echoes it back", %{conn: conn} do
      account = account!(:claude, "pv-rotate")
      {:ok, view, _html} = live(conn, ~p"/providers")

      view |> element("#account-#{account.id}-credential-button") |> render_click()

      assert has_element?(view, "#credential-form-#{account.id} input[type=password][name='credential[secret]']")

      html =
        view
        |> form("#credential-form-#{account.id}",
          credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: @secret}
        )
        |> render_submit()

      assert [credential] = active_credentials(account)
      assert ProviderCredential.secret(credential) == @secret
      refute html =~ @secret
      refute render(view) =~ @secret

      assert has_element?(
               view,
               "#account-#{account.id}-credentials",
               String.slice(credential.fingerprint, 0, 12)
             )
    end

    test "rotating retires the previous credential", %{conn: conn} do
      account = account!(:claude, "pv-rotate-twice")

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-ant-oat01-old"
        })

      {:ok, view, _html} = live(conn, ~p"/providers")
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      view
      |> form("#credential-form-#{account.id}",
        credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: @secret}
      )
      |> render_submit()

      assert [credential] = active_credentials(account)
      assert ProviderCredential.secret(credential) == @secret
    end

    test "a failed submit reports the error without echoing the secret", %{conn: conn} do
      account = account!(:claude, "pv-rotate-bad")
      {:ok, view, _html} = live(conn, ~p"/providers")
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      html =
        view
        |> form("#credential-form-#{account.id}",
          credential: %{kind: "oauth_token", env_var: "", secret: @secret}
        )
        |> render_submit()

      assert active_credentials(account) == []
      assert has_element?(view, "#credential-form-#{account.id}-error")
      refute html =~ @secret
    end

    test "a blank secret is refused", %{conn: conn} do
      account = account!(:claude, "pv-rotate-blank")
      {:ok, view, _html} = live(conn, ~p"/providers")
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      view
      |> form("#credential-form-#{account.id}",
        credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: "  "}
      )
      |> render_submit()

      assert active_credentials(account) == []
      assert has_element?(view, "#credential-form-#{account.id}-error")
    end

    test "the secret param is filtered out of LiveView's event logging" do
      assert %{"credential" => %{"secret" => "[FILTERED]"}} =
               Phoenix.Logger.filter_values(%{"credential" => %{"secret" => @secret}})
    end
  end

  describe "attach and detach" do
    setup do
      enable!(true)
      :ok
    end

    test "attaches a workspace to the account", %{conn: conn} do
      ws = workspace!("pv-attach-me")
      account = account!(:claude, "pv-attach")
      {:ok, view, _html} = live(conn, ~p"/providers")

      view |> element("#account-#{account.id}-attach-button") |> render_click()

      view
      |> form("#attach-form-#{account.id}", attach: %{workspace_id: ws.id, share: "2"})
      |> render_submit()

      assert [%{workspace_id: ws_id, share: 2}] = links(account)
      assert ws_id == ws.id
      assert has_element?(view, "#account-#{account.id}-ws-#{ws.id}", "pv-attach-me")
    end

    test "detaches a workspace from the account", %{conn: conn} do
      ws = workspace!("pv-detach-me")
      account = account!(:claude, "pv-detach")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)
      {:ok, view, _html} = live(conn, ~p"/providers")

      view |> element("#detach-#{account.id}-#{ws.id}") |> render_click()

      assert links(account) == []
      refute has_element?(view, "#account-#{account.id}-ws-#{ws.id}")
    end
  end

  describe "with accounts disabled" do
    setup do
      enable!(false)
      :ok
    end

    test "lists accounts read-only under an explicit notice", %{conn: conn} do
      ws = workspace!("pv-ro")
      account = account!(:claude, "pv-readonly")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live(conn, ~p"/providers")

      assert has_element?(view, "#accounts-disabled-notice", "Accounts not enabled on this install")
      assert has_element?(view, "#account-#{account.id}")
      refute has_element?(view, "#new-account-button")
      refute has_element?(view, "#account-#{account.id}-credential-button")
      refute has_element?(view, "#account-#{account.id}-attach-button")
      refute has_element?(view, "#detach-#{account.id}-#{ws.id}")
    end

    test "the server refuses every action, not just the hidden buttons", %{conn: conn} do
      ws = workspace!("pv-ro-2")
      account = account!(:claude, "pv-readonly-2")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)
      {:ok, view, _html} = live(conn, ~p"/providers")

      render_hook(view, "create_account", %{"account" => %{"provider" => "claude", "slug" => "sneaky"}})

      render_hook(view, "rotate_credential", %{
        "account_id" => account.id,
        "credential" => %{"kind" => "oauth_token", "env_var" => "X", "secret" => @secret}
      })

      render_hook(view, "detach", %{"account" => account.id, "workspace" => ws.id})

      assert {:error, :not_found} = Accounts.get_account("claude:sneaky")
      assert active_credentials(account) == []
      assert [_] = links(account)
      refute render(view) =~ @secret
    end
  end
end
