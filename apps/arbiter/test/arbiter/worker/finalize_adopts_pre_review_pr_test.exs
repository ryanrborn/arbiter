defmodule Arbiter.Worker.FinalizeAdoptsPreReviewPRTest do
  @moduledoc """
  Regression test for bd-28l6im: on APPROVE, `do_open_mr` must not race a
  second `adapter.open/4` call against the PR the worker's own pre-review
  open (`maybe_open_pr_for_review`, bd-129xh4) already created on this exact
  branch.

  `Arbiter.Worker.ReopenAfterReviewGateTest` (bd-636thc) proves that *when*
  this second call races and transiently misses its own look-before-create
  and 422 fallback, `Mergers.open_with_retry/5` gives it another shot. But
  three finalize-422 false-failures landed in one afternoon (bd-8cn795,
  bd-7opdaf, bd-2wilou) even with that retry in place — the transient
  GitHub-listing miss window can outlast the retry budget. The more direct
  fix is to not race a second `open/4` call *at all* when this worker
  already knows the PR ref from its own pre-review open: `do_open_mr` now
  checks `meta[:review_pr_ref]` (recorded by `enter_review_gate` for this
  exact branch) and adopts it directly, skipping `adapter.open/4` entirely.

  This test proves that: after APPROVE, the finalize step issues zero
  `GET`/`POST` calls to `/pulls` — it only re-pushes the branch (to carry any
  revise-and-discuss commits) and adopts the known ref.
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
        name: "finalize-adopts-pre-review-ws-#{System.unique_integer([:positive])}",
        prefix: "fap",
        config: @ws_github_review
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "finalize adopts pre-review pr",
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

  test "APPROVE adopts the pre-review PR ref without any further /pulls calls" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/1025-finalize-adopts-pre-review-pr"
    pid = start_worker(task, ws, branch)

    {:ok, calls} = Agent.start_link(fn -> %{get: 0, post: 0} end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/#{@owner}/#{@repo}/pulls"} ->
          Agent.update(calls, fn c -> %{c | get: c.get + 1} end)
          # Pre-review open/4's look-before-create: no PR yet. Any call past
          # that is a bug — the finalize step must not hit this endpoint again.
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        {"POST", "/repos/#{@owner}/#{@repo}/pulls"} ->
          Agent.update(calls, fn c -> %{c | post: c.post + 1} end)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 700,
            "html_url" => "https://github.com/#{@owner}/#{@repo}/pull/700"
          })

        {"POST", "/repos/#{@owner}/#{@repo}/pulls/700/requested_reviewers"} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)

    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

    {:ok, mid_task} = Ash.get(Issue, task.id)
    assert mid_task.pr_ref == "#700"
    assert Agent.get(calls, & &1) == %{get: 1, post: 1}

    :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

    wait_until(fn -> Worker.state(pid).status == :awaiting_review end, 3_000)

    snap = Worker.state(pid)
    refute snap.status == :failed
    assert snap.mr_ref == "#700"

    # The finalize step must not have issued a SECOND open/4 call at all —
    # no additional GET or POST to /pulls beyond the pre-review open.
    assert Agent.get(calls, & &1) == %{get: 1, post: 1}

    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.pr_ref == "#700"

    escalations = Message.inbox("admiral", workspace_id: ws.id)
    refute Enum.any?(escalations, &(&1.directive_ref == task.id and &1.kind == :escalation))
  end
end
