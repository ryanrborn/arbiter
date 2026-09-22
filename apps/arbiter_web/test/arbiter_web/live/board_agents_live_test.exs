defmodule ArbiterWeb.BoardAgentsLiveTest do
  @moduledoc """
  bd-aw2cyt: the board header counts live agents, and a card with no live
  agent behind it is visibly distinguished from one that is burning quota.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "agents-#{System.unique_integer([:positive])}",
        prefix: "ag#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp task(ws, title) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- fixture"})

    {:ok, issue} = Ash.update(issue, %{}, action: :promote_to_ready)
    issue
  end

  test "the header reports how many agents are live out of the cap", %{conn: conn, ws: ws} do
    t = task(ws, "no agent behind it")
    {:ok, pid} = Worker.start(task_id: t.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(t.id, :normal) end)

    {:ok, view, _html} = live(conn, "/")

    slots = view |> element("#board-slots") |> render()

    # The record is `running`; no agent is live for it, so the count is 0.
    assert slots =~ "agents live"
    assert slots =~ "0 of"
  end

  test "a running card with no live agent is marked as such", %{conn: conn, ws: ws} do
    t = task(ws, "stalled card")
    {:ok, pid} = Worker.start(task_id: t.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(t.id, :normal) end)

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#card-#{t.id} [data-agent-live='false']")
    assert has_element?(view, "#card-#{t.id} [data-phase]")
  end
end
