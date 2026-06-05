defmodule ArbiterWeb.ConvoyIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Convoy, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ci-#{System.unique_integer([:positive])}", prefix: "cix"})

    {:ok, ws: ws}
  end

  test "lists all campaigns with their progress", %{conn: conn, ws: ws} do
    {:ok, _c} = Ash.create(Convoy, %{title: "the-grand-campaign", workspace_id: ws.id})

    {:ok, _view, html} = live(conn, ~p"/convoys")

    assert html =~ "the-grand-campaign"
    assert html =~ ~s(id="convoys")
  end

  test "the closed filter excludes open campaigns", %{conn: conn, ws: ws} do
    {:ok, _open} = Ash.create(Convoy, %{title: "open-campaign", workspace_id: ws.id})
    {:ok, c2} = Ash.create(Convoy, %{title: "closed-campaign", workspace_id: ws.id})
    {:ok, _} = Ash.update(c2, %{reason: "done"}, action: :close)

    {:ok, _view, html} = live(conn, ~p"/convoys?#{%{status: :closed}}")

    assert html =~ "closed-campaign"
    refute html =~ "open-campaign"
  end

  test "empty filter renders the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/convoys?#{%{status: :closed}}")
    assert html =~ ~s(id="convoys-empty")
  end

  test "a row links to the convoy detail page", %{conn: conn, ws: ws} do
    {:ok, c} = Ash.create(Convoy, %{title: "linkable-campaign", workspace_id: ws.id})

    {:ok, _view, html} = live(conn, ~p"/convoys")
    assert html =~ ~s(href="/convoys/#{c.id}")
  end
end
