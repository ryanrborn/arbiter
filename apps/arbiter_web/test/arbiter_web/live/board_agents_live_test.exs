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
    # Stop every stray worker and wait on the DOWNs, not a clock: the header
    # this file asserts on counts the whole fleet.
    refs =
      for snap <- Worker.list_children(), pid = Worker.whereis(snap.task_id), is_pid(pid) do
        ref = Process.monitor(pid)
        Worker.stop(snap.task_id)
        ref
      end

    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)

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

  test "a live agent subprocess is what the header counts", %{conn: conn, ws: ws} do
    quiet = task(ws, "record only")
    {:ok, quiet_pid} = Worker.start(task_id: quiet.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(quiet_pid, :implement)

    busy = task(ws, "agent live")
    {:ok, busy_pid} = Worker.start(task_id: busy.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(busy_pid, :implement)

    on_exit(fn ->
      for {pid, id} <- [{quiet_pid, quiet.id}, {busy_pid, busy.id}],
          Process.alive?(pid),
          do: Worker.stop(id, :normal)
    end)

    # A real OS subprocess owned by the worker, opened through the same
    # handle_call `Worker.ClaudeSession.start/1` uses.
    cat = System.find_executable("cat")

    {:ok, port} =
      GenServer.call(
        busy_pid,
        {:__claude_session_open__, %{exec: cat, argv: [cat], cd: System.tmp_dir!(), env: []},
         %{provider: :claude}}
      )

    assert is_port(port)

    {:ok, view, _html} = live(conn, "/")

    slots = view |> element("#board-slots") |> render()
    assert slots =~ "1 of"

    # Two `running` records, one live agent — the quiet one is the card this
    # ticket exists to stop calling "running".
    assert has_element?(view, "#card-#{busy.id} [data-agent-live='true']")
    assert has_element?(view, "#card-#{quiet.id} [data-agent-live='false']")
  end

  test "the workers index shows the phase and dims a row with no live agent", %{
    conn: conn,
    ws: ws
  } do
    t = task(ws, "workers index row")
    {:ok, pid} = Worker.start(task_id: t.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(t.id, :normal) end)

    {:ok, view, _html} = live(conn, "/workers")

    assert has_element?(view, "[data-phase][data-agent-live='false']")
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
