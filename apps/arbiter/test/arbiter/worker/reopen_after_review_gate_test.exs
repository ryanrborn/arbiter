defmodule Arbiter.Worker.ReopenAfterReviewGateTest do
  @moduledoc """
  Regression test for bd-636thc: finalize's 422 "already exists" adoption
  (bd-8rrn9t / bd-8iad6a / bd-c5zu16) is implemented *inside* one call to
  `Arbiter.Mergers.Github.open/4` — a look-before-create GET, and (on a 422)
  a single reactive fallback GET. `Arbiter.Worker.FinalizePRAlreadyExistsTest`
  (#968) proves that single-call mechanism works when a PR was opened by
  some other process before the worker's *only* `open/4` call.

  It does NOT cover a worker with a review gate: `enter_review_gate` opens a
  real PR itself (bd-129xh4, `maybe_open_pr_for_review`) *before* the
  reviewer runs, then APPROVE drives a *second*, independent `open/4` call
  (`do_open_mr`) on the very same branch to actually integrate. If GitHub's
  PR-listing endpoint has a transient hiccup right when that second call's
  own look-before-create *and* its own 422 fallback both miss — plausible
  after a burst of review-related API traffic — bd-8rrn9t/bd-8iad6a's
  single-shot adoption inside that one `open/4` call is exhausted and the
  raw 422 bubbles up through `do_open_mr` -> `merge_branch` ->
  `park_merge_failure`, failing the run via `{:merge_failed, reason}` even
  though the worker's own earlier PR is sitting right there, open, on the
  same branch (bd-887swr run a7ce18d4).

  The fix: `Arbiter.Mergers.open_with_retry/5` retries the whole `open/4`
  call (not just the lookup inside it) when the failure is an "already
  exists" 409/422, giving the adoption lookup another shot. `Worker.safe_open/5`
  (shared by `do_open_mr` and `open_pr_without_merge`) and
  `MergeQueue.open_mr_for/4` (the auto-merge / MergeQueue path) both route
  through it, so every path that can open an MR for a task's own branch gets
  the same resilience.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  @owner "octo"
  @repo "widget"
  @token "test-token-abc123"

  @ws_github_review %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => @token
      }
    },
    "review" => %{"required" => true}
  }

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  defp new_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "reopen-review-gate-ws-#{System.unique_integer([:positive])}",
        prefix: "rag",
        config: @ws_github_review
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "reopen after review gate",
        workspace_id: ws.id,
        issue_type: :feature
      })

    task
  end

  defp start_worker(task, ws, branch) do
    meta = %{
      branch: branch,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_spawn: false
    }

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "widget", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  test "a second open/4 call after APPROVE adopts the worker's own pre-review PR even when " <>
         "its own look-before-create and 422 fallback both miss on the first attempt" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/990-reopen-after-review-gate"
    pid = start_worker(task, ws, branch)

    {:ok, calls} = Agent.start_link(fn -> %{get: 0, post: 0} end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/#{@owner}/#{@repo}/pulls"} ->
          n = Agent.get_and_update(calls, fn c -> {c.get, %{c | get: c.get + 1}} end)

          case n do
            # Pre-review open/4's look-before-create: no PR yet.
            0 ->
              conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

            # do_open_mr's FIRST open/4 call: both its look-before-create (1)
            # and its own 422-triggered fallback (2) transiently miss the PR
            # that's genuinely open on GitHub — the exact gap #968 doesn't
            # cover (there, only the pre-check misses; the fallback hits).
            n when n in [1, 2] ->
              conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

            # open_with_retry's SECOND open/4 call: the hiccup has passed —
            # the look-before-create now finds the real, still-open PR.
            _ ->
              conn
              |> Plug.Conn.put_status(200)
              |> Req.Test.json([
                %{"number" => 700, "state" => "open", "head" => %{"ref" => branch}}
              ])
          end

        {"POST", "/repos/#{@owner}/#{@repo}/pulls"} ->
          n = Agent.get_and_update(calls, fn c -> {c.post, %{c | post: c.post + 1}} end)

          case n do
            # Pre-review open/4: genuinely creates PR #700.
            0 ->
              conn
              |> Plug.Conn.put_status(201)
              |> Req.Test.json(%{
                "number" => 700,
                "html_url" => "https://github.com/#{@owner}/#{@repo}/pull/700"
              })

            # do_open_mr's FIRST open/4 call: races its own pre-review PR,
            # 422s exactly like production did.
            _ ->
              conn
              |> Plug.Conn.put_status(422)
              |> Req.Test.json(%{
                "message" => "Validation Failed",
                "errors" => [
                  %{
                    "code" => "custom",
                    "message" => "A pull request already exists for #{@owner}:#{branch}."
                  }
                ]
              })
          end

        {"POST", "/repos/#{@owner}/#{@repo}/pulls/700/requested_reviewers"} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)

    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

    # The pre-review open adopted-in-advance the ref onto the task already.
    {:ok, mid_task} = Ash.get(Issue, task.id)
    assert mid_task.pr_ref == "#700"

    :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

    wait_until(fn -> Worker.state(pid).status == :awaiting_review end, 3_000)

    snap = Worker.state(pid)
    refute snap.status == :failed
    assert snap.mr_ref == "#700"

    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.pr_ref == "#700"

    # No failure escalation was raised — this was a success, not a stranded run.
    escalations = Message.inbox("admiral", workspace_id: ws.id)
    refute Enum.any?(escalations, &(&1.directive_ref == task.id and &1.kind == :escalation))
  end
end
