defmodule Arbiter.Workflows.MergeQueuePostApprovalPushTest do
  @moduledoc """
  P7 (bd-60r6wp / #1738) — the MergeQueue half of §4.5: a conflict-resolver
  push onto an approved PR is no longer treated as reviewed.

  Before P7 the queue's `clear_reviewed_latch/1` suspended the guard for the
  resolver's force-push and re-latched onto whatever head it produced, so a
  resolution that wrote content merged with no review having seen it. Now the
  approved baseline stays pinned: a resolution whose net diff equals the
  approved one merges on a `:mechanical` coverage row, and one that authored
  content is refused until a review covers it.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    @moduledoc false
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  defmodule PushingResolver do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    @impl true
    def resolve(_args), do: {:ok, %{worker: :stub}}

    @impl true
    def escalate_unresolved(_task_id, _ws_id, _branch, _reason), do: :ok

    @impl true
    def notify_resolution(_task_id, _ws_id, _branch), do: :ok
  end

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123"
      }
    }
  }

  @approved_diff """
  diff --git a/lib/widget.ex b/lib/widget.ex
  index 1111111..2222222 100644
  --- a/lib/widget.ex
  +++ b/lib/widget.ex
  @@ -10,6 +10,7 @@ defmodule Widget do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # The approved change replayed onto the moved base: no content line differs.
  @rebased_diff """
  diff --git a/lib/widget.ex b/lib/widget.ex
  index 3333333..4444444 100644
  --- a/lib/widget.ex
  +++ b/lib/widget.ex
  @@ -61,6 +61,7 @@ defmodule Widget do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # The resolution wrote a line nobody reviewed.
  @authored_diff """
  diff --git a/lib/widget.ex b/lib/widget.ex
  index 3333333..5555555 100644
  --- a/lib/widget.ex
  +++ b/lib/widget.ex
  @@ -61,6 +61,8 @@ defmodule Widget do
     def run do
       :ok
  +    :extra
  +    :resolved_by_hand
     end
   end
  """

  setup do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "mq#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    %{workspace: workspace}
  end

  defp sha(seed), do: Base.encode16(:crypto.hash(:sha, seed), case: :lower)

  defp start_merge_queue(workspace) do
    name = :"merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree,
        conflict_resolver: PushingResolver
      )

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    name
  end

  # A GitHub stub whose PR state lives in `agent` and whose three-dot compare
  # answers from `diffs` (keyed by head sha).
  defp github_stub(agent, number, diffs) do
    test_pid = self()

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      pr = Agent.get(agent, & &1)
      path = conn.request_path
      accept = conn |> Plug.Conn.get_req_header("accept") |> List.first() || ""

      cond do
        conn.method == "GET" and String.ends_with?(path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

        conn.method == "PUT" and String.ends_with?(path, "/merge") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:merged, Jason.decode!(body)["sha"]})
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true, "sha" => "ok"})

        conn.method == "GET" and String.contains?(path, "/compare/") and accept =~ "diff" ->
          [_, head] = Regex.run(~r{\.\.\.([0-9a-f]+)$}, path)
          send(test_pid, {:diffed, head})
          Plug.Conn.send_resp(conn, 200, Map.get(diffs, head, ""))

        conn.method == "GET" and String.contains?(path, "/compare/") ->
          # Ancestry probe: nothing here is a lagging forge.
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"status" => "diverged"})

        conn.method == "GET" and String.contains?(path, "/pulls/#{number}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(
            Map.merge(
              %{
                "number" => number,
                "state" => "open",
                "base" => %{"ref" => "main"},
                "html_url" => "https://github.com/octo/widget/pull/#{number}"
              },
              pr
            )
          )

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  # Approve at `approved` (the task's stamp plus a `:reviewed` row), watch the
  # PR go CONFLICTING, let the resolver force-push `pushed`, and tick until the
  # queue has decided about it.
  defp resolver_push(ws, number, approved, pushed, pushed_diff) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{"head" => %{"sha" => approved}, "mergeable" => false, "mergeStateStatus" => "dirty"}
      end)

    github_stub(agent, number, %{approved => @approved_diff, pushed => pushed_diff})

    {:ok, task} = Ash.create(Issue, %{title: "p7 queue", workspace_id: ws.id})

    {:ok, task} =
      Ash.update(task, %{pr_ref: "##{number}", last_reviewed_sha: approved}, action: :update)

    name = start_merge_queue(ws)
    :ok = MergeQueue.enqueue(name, task.id)
    %{items: [item]} = MergeQueue.state(name)

    {:ok, entry} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: item.mr_ref,
        head_sha: approved,
        base_ref: "main",
        net_diff_id: NetDiff.fingerprint(@approved_diff),
        kind: :reviewed,
        source: :review_gate
      })

    # Tick 1: conflicting → the resolver is spawned.
    capture_log(fn -> :ok = MergeQueue.tick(name) end)
    %{items: [item]} = MergeQueue.state(name)
    assert item.status == :conflict_resolving

    # The resolver force-pushed; the PR is clean again.
    Agent.update(agent, fn _ ->
      %{"head" => %{"sha" => pushed}, "mergeable" => true, "mergeStateStatus" => "clean"}
    end)

    capture_log(fn -> for _ <- 1..3, do: :ok = MergeQueue.tick(name) end)

    %{task: task, name: name, item: item, entry: entry}
  end

  defp coverage_for(mr_ref, head), do: Enum.filter(Coverage.for_mr(mr_ref), &(&1.head_sha == head))

  test "a resolution that authored content is refused, and nothing records its head as reviewed",
       %{workspace: ws} do
    approved = sha("mq-approved-authored")
    pushed = sha("mq-resolved-authored")

    %{task: task, name: name, item: item} =
      resolver_push(ws, 311, approved, pushed, @authored_diff)

    refute_received {:merged, _}
    assert Ash.get!(Issue, task.id).status == :open

    %{items: [after_item]} = MergeQueue.state(name)
    assert {:stale_reviewed_sha, ^approved, ^pushed} = after_item.last_error
    assert coverage_for(item.mr_ref, pushed) == []

    # Three ticks at the refused head ran the content check once, not per tick.
    # (Only that check diffs the reviewed commit; the coverage shadow
    # fingerprints the head alone.)
    assert_received {:diffed, ^approved}
    refute_received {:diffed, ^approved}
  end

  test "a resolution whose net diff equals the approved one merges on a :mechanical row",
       %{workspace: ws} do
    approved = sha("mq-approved-equal")
    pushed = sha("mq-resolved-equal")

    %{task: task, item: item, entry: entry} =
      resolver_push(ws, 312, approved, pushed, @rebased_diff)

    assert_received {:merged, ^pushed}
    assert Ash.get!(Issue, task.id).status == :closed

    assert [%{kind: :mechanical} = row] = coverage_for(item.mr_ref, pushed)
    assert row.derived_from == entry.id
  end
end
