defmodule ArbiterWeb.WorkerIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-#{System.unique_integer([:positive])}", prefix: "pix"})

    {:ok, ws: ws}
  end

  test "empty state when no workers are active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")
    assert html =~ ~s(id="workers-empty")
  end

  test "lists an active worker with its workspace, linking to detail", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "active-worker", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ ~s(id="workers")
    assert html =~ task.id
    assert html =~ ws.name
    assert html =~ ~s(href="/workers/#{task.id}")
  end

  test "live: stopping an worker removes it via PubSub", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "soon-stopped", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, view, _html} = live(conn, ~p"/workers")
    assert render(view) =~ task.id

    Worker.stop(task.id)
    Process.sleep(150)

    refute render(view) =~ task.id
  end
end
