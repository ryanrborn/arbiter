defmodule ArbiterWeb.WorkerIndexLiveTest.TestMerger do
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!99"}
  @impl true
  def get(_ref), do: {:ok, %{status: :open, approved: false}}
  @impl true
  def merge(_ref, _expected_sha), do: :ok
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
  @impl true
  def list_review_feedback(_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}
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
      interval_ms: 600_000,
      initial_delay_ms: 600_000
    }
  end

  test "empty state when no workers are active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")
    assert html =~ ~s(id="workers-empty")
    assert html =~ "hero-moon"
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

  test "shows the worker's provider icon", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "provider-worker", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.report(pid, :provider, "gemini")

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ ~s(aria-label="Gemini")
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
    # When CI is not running, should show "Open · awaiting approval"
    assert html =~ "Open · awaiting approval"
  end

  test "awaiting review worker with running CI shows CI running badge", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "ci-running-task", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)
    {:ok, _} = Worker.open_mr(pid, "feature/test", "Test", "", merge_opts())

    # Record merger status: MR is open, not approved, but CI is running
    :ok = Worker.record_merger_status(pid, %{status: :open, approved: false, pipeline: :running})

    {:ok, _view, html} = live(conn, ~p"/workers?status=awaiting")

    assert html =~ task.id
    # When CI is running, should show "Open · CI running"
    assert html =~ "Open · CI running"
  end

  # bd-45tkhq round 2: a wedged worker whose registry key has no matching
  # `Arbiter.Workers.Run` row degrades to `started_at: nil` (Worker.worker_test.exs
  # covers the degrade path itself). `refresh/1`'s `Enum.sort_by(&1.started_at,
  # {:asc, DateTime})` had no nil clause and crashed the whole page on every
  # `:worker_lifecycle` refresh once such an entry existed, alongside a normal
  # worker with a real `started_at`.
  test "a degraded entry with nil started_at does not crash the page", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "normal-worker", workspace_id: ws.id})
    {:ok, normal_pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, normal_pid) end)

    orphan_task_id = "gte-orphan-#{System.unique_integer([:positive])}"

    {:ok, wedged_pid} =
      Worker.start(
        task_id: orphan_task_id,
        repo: "test/repo",
        workspace_id: ws.id,
        registry_key: "unmatched-registry-key-#{System.unique_integer([:positive])}"
      )

    # bd-5scl0c: `:sys.suspend/2` a worker so `list_children/0` genuinely hits
    # the degrade path, then hand teardown to `ProcessTeardown.stop_child/3`
    # rather than a bare `:sys.resume/2` — it quiesces before terminating, so
    # a suspended worker still holding the shared sandbox connection can't be
    # killed mid-checkout and take the connection down with it.
    :sys.suspend(wedged_pid)
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, wedged_pid) end)

    {:ok, _view, html} = live(conn, ~p"/workers")
    assert html =~ task.id
  end
end
