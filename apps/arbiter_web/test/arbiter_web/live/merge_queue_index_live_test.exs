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
  @impl true
  def list_review_feedback(_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}
end

defmodule ArbiterWeb.MergeQueueIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

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

  describe "Queued tab" do
    test "empty state when nothing is integrating", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/merge_queue")
      assert html =~ ~s(id="merge_queue-empty")
      assert html =~ "integrating right now"
    end

    test "row anatomy: position, id, title, PR link, check dots, time-in-queue",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      {:ok, _view, html} = live(conn, ~p"/merge_queue")

      assert html =~ ~s(id="merge_queue")
      # position badge
      assert html =~ "#1"
      assert html =~ task.id
      assert html =~ "merging-now"
      assert html =~ "!77"
      assert html =~ "https://example.test/mr/77"
      assert html =~ ~s(href="/workers/#{task.id}")
      assert html =~ "in queue"
      # check dots — three checks (CI / Approval / Mergeable) rendered as dots
      assert html =~ "title=\"CI\""
      assert html =~ "title=\"Approval\""
      assert html =~ "title=\"Mergeable\""
    end

    test "Queued tab is the default and shows in the tab bar with a live count",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      {:ok, _view, html} = live(conn, ~p"/merge_queue")
      assert html =~ "Queued"
      assert html =~ "Landed today"
      assert html =~ "Rejected"
    end

    test "a draft PR lights the Mergeable dot red, not green", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "draft-pr", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      :ok =
        Worker.record_merger_status(pid, %{
          pipeline: :success,
          approved: true,
          block_reason: :draft
        })

      {:ok, _view, html} = live(conn, ~p"/merge_queue")

      [_, mergeable_dot] =
        Regex.run(~r/<span[^>]*title="Mergeable"[^>]*class="([^"]*)"/, html) ||
          Regex.run(~r/class="([^"]*)"[^>]*title="Mergeable"/, html)

      assert mergeable_dot =~ "bg-error"
    end

    test "an unknown/not-yet-started CI signal renders as unknown, not passed",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no-ci-yet", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      :ok = Worker.record_merger_status(pid, %{pipeline: :not_started, approved: false})

      {:ok, _view, html} = live(conn, ~p"/merge_queue")

      [_, ci_dot] =
        Regex.run(~r/class="([^"]*)"[^>]*title="CI"/, html) ||
          Regex.run(~r/<span[^>]*title="CI"[^>]*class="([^"]*)"/, html)

      refute ci_dot =~ "bg-success"
      assert ci_dot =~ "bg-base-300"
    end

    test "the header count and subtitle describe the active tab, not always Queued",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        mr_ref: "!42"
      })

      {:ok, _view, queued_html} = live(conn, ~p"/merge_queue")
      assert queued_html =~ "integrating now, longest-waiting first"

      {:ok, _view, landed_html} = live(conn, ~p"/merge_queue?tab=landed")
      refute landed_html =~ "integrating now, longest-waiting first"
      assert landed_html =~ "merged since midnight UTC"

      {:ok, _view, rejected_html} = live(conn, ~p"/merge_queue?tab=rejected")
      refute rejected_html =~ "integrating now, longest-waiting first"
      assert rejected_html =~ "reopen their task instead of collecting here"
    end
  end

  describe "Landed today tab" do
    test "shows a 3-col grid of muted TaskCards for runs completed today", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "shipped-thing", workspace_id: ws.id})

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        mr_ref: "!42"
      })

      {:ok, _view, html} = live(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed")
      assert html =~ "grid-cols-1"
      assert html =~ "lg:grid-cols-3"
      assert html =~ task.id
      assert html =~ "shipped-thing"
      assert html =~ "UTC"
      refute html =~ ~s(id="merge_queue-landed-empty")
    end

    test "empty state when nothing landed today", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/merge_queue?tab=landed")
      assert html =~ ~s(id="merge_queue-landed-empty")
      assert html =~ "landed today"
    end

    test "a run completed before today does not show up", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "old-news", workspace_id: ws.id})

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -172_800, :second),
        completed_at: DateTime.add(DateTime.utc_now(), -172_000, :second),
        mr_ref: "!41"
      })

      {:ok, _view, html} = live(conn, ~p"/merge_queue?tab=landed")
      assert html =~ ~s(id="merge_queue-landed-empty")
      refute html =~ "old-news"
    end
  end

  describe "Rejected tab" do
    test "always shows the empty state explaining a rejected merge reopens its task",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/merge_queue?tab=rejected")

      assert html =~ ~s(id="merge_queue-rejected-empty")
      assert html =~ "don&#39;t collect here"
      assert html =~ "reopens its task"
    end
  end
end
