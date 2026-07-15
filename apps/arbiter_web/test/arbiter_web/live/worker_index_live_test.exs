defmodule ArbiterWeb.WorkerIndexLiveTest.TestMerger do
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!99"}
  @impl true
  def get(_ref), do: {:ok, %{status: :open, approved: false}}
  @impl true
  def merge(_ref), do: :ok
  @impl true
  def close(_ref), do: :ok
  @impl true
  def add_comment(_ref, _body), do: :ok
  @impl true
  def request_review(_ref, _reviewers), do: :ok
  @impl true
  def link_for(_ref), do: "https://example.test/mr/99"
  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}
  @impl true
  def post_inline_comment(_ref, _finding, _opts), do: :ok
  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: :ok
end

defmodule ArbiterWeb.WorkerIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias ArbiterWeb.WorkerIndexLiveTest.TestMerger

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-#{System.unique_integer([:positive])}", prefix: "pix"})

    {:ok, ws: ws}
  end

  defp merge_opts do
    %{
      adapter: TestMerger,
      workspace: nil,
      auto_merge: false,
      interval_ms: 600_000
    }
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

  test "live: stopping a worker removes it via PubSub", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "soon-stopped", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, view, _html} = live(conn, ~p"/workers")
    assert render(view) =~ task.id

    Worker.stop(task.id)
    Process.sleep(150)

    refute render(view) =~ task.id
  end

  test "awaiting review worker shows expected badge status", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "awaiting-task", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)
    {:ok, _} = Worker.open_mr(pid, "feature/test", "Test", "", merge_opts())

    # Record merger status: MR is open, not approved (awaiting review)
    :ok = Worker.record_merger_status(pid, %{status: :open, approved: false})

    {:ok, _view, html} = live(conn, ~p"/workers?status=awaiting")

    assert html =~ task.id
    # When CI is not running, should show "Awaiting review"
    assert html =~ "Awaiting review"
  end
end
