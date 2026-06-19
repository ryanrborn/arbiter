defmodule ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger do
  @moduledoc "Stub merger that parks a polecat at :awaiting_review (see dashboard test)."
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
  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children(), do: Polecat.stop(snap.bead_id)
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

  test "an in-flight merge surfaces with its MR link and links to the polecat detail",
       %{conn: conn, ws: ws} do
    {:ok, bead} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
    {:ok, pid} = Polecat.start(bead_id: bead.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Polecat.advance(pid, :integrate)
    {:ok, "!77"} = Polecat.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

    {:ok, _view, html} = live(conn, ~p"/merge_queue")

    assert html =~ ~s(id="merge_queue")
    assert html =~ bead.id
    assert html =~ "!77"
    assert html =~ "https://example.test/mr/77"
    assert html =~ ~s(href="/polecats/#{bead.id}")
  end
end
