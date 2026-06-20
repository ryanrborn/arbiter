defmodule ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger do
  @moduledoc "Stub merger that parks a worker at :awaiting_review (see dashboard test)."
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!77"}
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
  def link_for(_ref), do: "https://example.test/mr/77"
  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}
  @impl true
  def post_inline_comment(_ref, _finding, _opts), do: :ok
  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: :ok
end

defmodule ArbiterWeb.MergeQueueIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "cr-#{System.unique_integer([:positive])}", prefix: "crx"})

    {:ok, ws: ws}
  end

  defp merge_opts do
    %{
      adapter: QueueMerger,
      workspace: nil,
      auto_merge: false,
      interval_ms: 600_000,
      initial_delay_ms: 600_000
    }
  end

  test "empty state when nothing is integrating", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/merge_queue")
    assert html =~ ~s(id="merge_queue-empty")
  end

  test "an in-flight merge surfaces with its MR link and links to the worker detail",
       %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)
    {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

    {:ok, _view, html} = live(conn, ~p"/merge_queue")

    assert html =~ ~s(id="merge_queue")
    assert html =~ task.id
    assert html =~ "!77"
    assert html =~ "https://example.test/mr/77"
    assert html =~ ~s(href="/workers/#{task.id}")
  end
end
