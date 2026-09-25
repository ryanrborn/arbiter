defmodule ArbiterWeb.WorkspaceProviderSettingsLiveTest do
  @moduledoc """
  bd-64apru: the workspace page's Providers section — allowed accounts per
  role, preference order, concurrency share, and the effective resolved
  setting with its config fallback.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts.{ProviderAccount, ProviderSettings, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "wps-#{System.unique_integer([:positive])}",
      prefix: "wp",
      config: config
    })
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp click(view, event, role, account) do
    view
    |> element(~s(button[phx-click=#{event}][phx-value-role=#{role}][phx-value-account="#{account.id}"]))
    |> render_click()
  end

  defp open(conn, ws) do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")
    view |> element(~s(#ws-rail button[phx-value-section=providers])) |> render_click()
    view
  end

  defp source(view, role) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#provider-effective-#{role}")
    |> LazyHTML.attribute("data-source")
    |> List.first()
  end

  test "the rail has a Providers section", %{conn: conn} do
    view = open(conn, workspace!())

    assert has_element?(view, ~s(#ws-rail button[phx-value-section=providers][aria-selected=true]))
    assert has_element?(view, "#provider-settings")
  end

  test "with nothing attached, shows the config fallback as the effective setting", %{conn: conn} do
    ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
    view = open(conn, ws)

    assert source(view, "implementer") == "agent_type"
    assert source(view, "reviewer") == "implementer"

    assert has_element?(view, "#provider-effective-implementer [data-candidate=codex]")
    assert has_element?(view, "#provider-effective-implementer [data-candidate=claude]")

    # The fallback editor is the old agent.type precedence list.
    assert has_element?(view, ~s(button[phx-click=remove_agent_type][phx-value-role=agent]))
  end

  test "adds an account to a role, persists it and projects agent.type", %{conn: conn} do
    ws = workspace!()
    codex = account!(:codex, "wps-codex")
    view = open(conn, ws)

    click(view, "add_role_account", "implementer", codex)

    assert has_element?(view, "#provider-role-implementer-#{codex.id}")
    assert source(view, "implementer") == "attached"

    reloaded = Ash.get!(Workspace, ws.id)
    assert reloaded.config["agent"]["type"] == "codex"
    assert ProviderSettings.effective(reloaded, :implementer).source == :attached

    # agent.type is now written from the list, so its hand editor is gone.
    refute has_element?(view, ~s(button[phx-click=add_agent_type][phx-value-role=agent]))
  end

  test "reorders and removes accounts in a role", %{conn: conn} do
    ws = workspace!()
    codex = account!(:codex, "wps-mv-codex")
    claude = account!(:claude, "wps-mv-claude")
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, codex.id)
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, claude.id)
    view = open(conn, ws)

    view
    |> element(
      ~s(button[phx-click=move_role_account][phx-value-role=reviewer][phx-value-account="#{claude.id}"][phx-value-dir=up])
    )
    |> render_click()

    assert Ash.get!(Workspace, ws.id).config["review_agent"]["type"] == ["claude", "codex"]

    click(view, "remove_role_account", "reviewer", claude)

    refute has_element?(view, "#provider-role-reviewer-#{claude.id}")
    assert Ash.get!(Workspace, ws.id).config["review_agent"]["type"] == "codex"
  end

  test "explains why a second account for a used provider is refused", %{conn: conn} do
    ws = workspace!()
    a = account!(:claude, "wps-taken-a")
    b = account!(:claude, "wps-taken-b")
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, a.id)
    view = open(conn, ws)

    click(view, "add_role_account", "implementer", b)

    assert has_element?(view, "#provider-settings-error", "wps-taken-a")
    refute has_element?(view, "#provider-role-implementer-#{b.id}")
  end

  test "sets and clears the workspace's concurrency share of an account", %{conn: conn} do
    ws = workspace!()
    acct = account!(:claude, "wps-share", %{max_concurrent: 4})
    {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)
    view = open(conn, ws)

    view |> form("#share-form-#{acct.id}", %{"share" => "2"}) |> render_submit()

    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == 2
    assert has_element?(view, "#share-cap-#{acct.id}", "2")

    view |> form("#share-form-#{acct.id}", %{"share" => ""}) |> render_submit()
    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == nil

    view |> form("#share-form-#{acct.id}", %{"share" => "-3"}) |> render_submit()
    assert has_element?(view, "#provider-settings-error")
    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == nil
  end

  test "adopts the accounts the fallback already resolves to", %{conn: conn} do
    ws = workspace!(%{"agent" => %{"type" => "claude"}})
    acct = account!(:claude, "wps-adopt")
    link!(ws, acct)
    view = open(conn, ws)

    view |> element("#adopt-implementer") |> render_click()

    assert source(view, "implementer") == "attached"
    assert has_element?(view, "#provider-role-implementer-#{acct.id}")
  end

  test "offers no adopt action when no fallback type has an account", %{conn: conn} do
    view = open(conn, workspace!(%{"agent" => %{"type" => "claude"}}))

    refute has_element?(view, "#adopt-implementer")
  end
end
