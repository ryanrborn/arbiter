defmodule Arbiter.Worker.FinalizePRStrandedEscalationTest do
  @moduledoc """
  Regression test for bd-28l6im's Wanted #3: "no task is parked failed
  while its PR is OPEN and MERGEABLE; that state escalates distinctly from a
  real work failure."

  `Mergers.open_with_retry/5` (bd-636thc, widened by bd-28l6im) gives the
  adoption lookup many chances to resolve an "already exists" 422 before
  giving up. If every one of those attempts still can't resolve a PR number
  — this test forces that by never returning one — the run genuinely cannot
  proceed automatically. It must still fail (there is no ref to adopt), but
  the escalation must say plainly that this is a PR-open collision likely
  to already be open and mergeable, not lump it in with an ordinary "could
  not be opened/merged" failure a human would read as needing a fresh look
  at the code.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  @owner "octo"
  @repo "widget"
  @token "test-token-abc123"

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => @token
      }
    }
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
        name: "finalize-pr-stranded-ws-#{System.unique_integer([:positive])}",
        prefix: "fps",
        config: @ws_github
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "finalize pr stranded",
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
      # Keep the retry-exhaustion path fast in the test — the underlying
      # error can never resolve here, so let it exhaust quickly rather than
      # waiting out the real multi-second production backoff.
      open_retry_opts: [attempts: 2, delay_ms: 1, max_delay_ms: 1]
    }

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "widget", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  test "an already-exists 422 that never resolves fails the run but escalates distinctly" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/1025-never-resolves"
    pid = start_worker(task, ws, branch)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/#{@owner}/#{@repo}/pulls"} ->
          # The PR the 422 insists exists is never actually found — the
          # genuinely-unresolvable edge case.
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        {"POST", "/repos/#{@owner}/#{@repo}/pulls"} ->
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

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> Worker.state(pid).status == :failed end)

    {:ok, reloaded} = Ash.get(Issue, task.id)
    refute reloaded.status == :closed

    escalations = Message.inbox("admiral", workspace_id: ws.id)

    escalation =
      Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

    assert escalation
    assert escalation.subject =~ "PR already exists"
    assert escalation.body =~ branch
    assert escalation.body =~ "NOT necessarily a work failure"
    refute escalation.subject =~ "could not be opened/merged"
  end
end
