defmodule ArbiterWeb.NavRailLiveTest do
  @moduledoc """
  The nav rail as mounted pages see it (bd-d63b1c): `Layouts.app/1` swapped
  the top bar's links for `sidebar_nav/1`, whose active item is resolved
  longest-match-wins. A plain prefix match would light up both `Workers` and
  `Run history` on a run's detail page; the rail must light up exactly one.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Workers.Run

  defp current_items(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([aria-current="page"]))
  end

  defp label(node), do: node |> LazyHTML.text() |> String.trim()

  test "the board lights up Board and nothing else", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert [item] = current_items(view) |> Enum.to_list()
    assert label(item) == "Board"
    assert has_element?(view, ~s(#nav-rail a[aria-current="page"][href="/"]))
  end

  test "a run's detail page lights up Run history, not Workers", %{conn: conn} do
    {:ok, run} =
      Ash.create(Run, %{
        repo: "arbiter",
        workspace_id: "ws-1",
        task_id: "bd-rail",
        task_title: "rail-run",
        status: :completed,
        worker_type: "main",
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        completed_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/workers/history/#{run.id}")

    assert [item] = current_items(view) |> Enum.to_list()
    assert label(item) == "Run history"

    assert has_element?(
             view,
             ~s(#nav-rail a[aria-current="page"][href="/workers/history"])
           )
  end
end
