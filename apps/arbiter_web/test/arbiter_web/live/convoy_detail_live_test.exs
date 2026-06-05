defmodule ArbiterWeb.ConvoyDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Convoy, ConvoyMembership, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "cd-#{System.unique_integer([:positive])}", prefix: "cdx"})

    {:ok, ws: ws}
  end

  defp attach(convoy, issue) do
    {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: convoy.id, issue_id: issue.id})
  end

  test "renders the convoy with its members and progress", %{conn: conn, ws: ws} do
    {:ok, convoy} = Ash.create(Convoy, %{title: "harvest-campaign", workspace_id: ws.id})
    {:ok, m1} = Ash.create(Issue, %{title: "member-one", workspace_id: ws.id})
    {:ok, m2} = Ash.create(Issue, %{title: "member-two", workspace_id: ws.id})
    attach(convoy, m1)
    attach(convoy, m2)
    {:ok, _} = Ash.update(m1, %{}, action: :close)

    {:ok, _view, html} = live(conn, ~p"/convoys/#{convoy.id}")

    assert html =~ "harvest-campaign"
    assert html =~ "member-one"
    assert html =~ "member-two"
    # One of two members closed.
    assert html =~ "1/2"
    assert html =~ ~s(id="convoy-issues")
    assert html =~ ~s(href="/beads/#{m1.id}")
  end

  test "renders a not-found panel for an unknown convoy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/convoys/cdx-cv-nope")
    assert html =~ "not found"
  end

  test "live: closing a member updates the progress via PubSub", %{conn: conn, ws: ws} do
    {:ok, convoy} = Ash.create(Convoy, %{title: "live-campaign", workspace_id: ws.id})
    {:ok, m1} = Ash.create(Issue, %{title: "pubsub-member", workspace_id: ws.id})
    attach(convoy, m1)

    {:ok, view, _html} = live(conn, ~p"/convoys/#{convoy.id}")
    assert render(view) =~ "0/1"

    {:ok, _} = Ash.update(m1, %{}, action: :close)

    assert render(view) =~ "1/1"
  end
end
