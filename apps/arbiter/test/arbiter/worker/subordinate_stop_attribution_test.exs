defmodule Arbiter.Worker.SubordinateStopAttributionTest do
  # bd-8lq2g7 / #1204 — a *subordinate* worker's death must not masquerade as the
  # task's primary worker dying.
  #
  # The merge queue starts subordinate workers under the task's OWN `task_id` but
  # a distinct registry key: the CI fix pass (`<task_id>:fixpass`, meta role
  # `:fix_pass`) and the conflict resolver (`<task_id>:conflict`). They run while
  # the primary author worker is parked at `:awaiting_review` awaiting the merge.
  #
  # When such a subordinate's agent exits 0 without `arb done`, the pre-fix code
  # ran the whole primary-worker failure path keyed on the base `task_id`:
  #
  #   * `Arbiter.Events.broadcast(ws, "worker_failed", %{task_id: task_id})`
  #     — which the Conductor consumes to pause the task's downstream branch, and
  #     which the API event stream reports as "the worker for <task> stopped";
  #   * a Coordinator escalation subject `"<task_id> stopped — exited without
  #     completing (exit 0)"` whose remediation reads "Resume: run `arb worker
  #     resume <task_id>`".
  #
  # Both are false: the task's own worker is alive and healthy at
  # `:awaiting_review`. Following that remediation is what produced the reported
  # loop — `worker_resume` is refused ("a worker is still active for this task
  # (awaiting_review)"), so the operator stops the healthy primary, and the
  # re-dispatch re-runs the whole ReviewGate from round 1.
  #
  # async: false — Port + Worker registry are global; DataCase gives the DB
  # sandbox the escalation + Run writes need.
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "subordinate-stop-ws", prefix: "sub"})
    {:ok, task} = Ash.create(Issue, %{title: "ship the thing", workspace_id: ws.id})
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))
    {:ok, ws: ws, task: task}
  end

  defp start_worker(ws, task, opts) do
    opts =
      Keyword.merge(
        [task_id: task.id, repo: "test/repo", workspace_id: ws.id],
        opts
      )

    {:ok, pid} = Worker.start(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Drive the worker's agent session to a clean exit that never prints the
  # `arb done` marker — the shape reported in #1204.
  defp exit_zero_without_done(pid, tag) do
    :ok = Worker.advance(pid, :claude)

    {:ok, _port} =
      Arbiter.Worker.ClaudeSession.start(
        owner: pid,
        worktree_path: tmp_dir!(tag),
        command: ["sh", "-c", "echo 'pushed the CI fix'; exit 0"]
      )

    eventually(fn ->
      case Worker.state(pid) do
        %{status: :failed} = s -> s
        _ -> nil
      end
    end)
  end

  defp eventually(fun, timeout_ms \\ 3_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    case fun.() do
      x when x in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(step_ms)
          do_eventually(fun, deadline, step_ms)
        end

      truthy ->
        truthy
    end
  end

  defp escalation_for(ws, task) do
    eventually(fn ->
      Message.inbox("admiral", workspace_id: ws.id)
      |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))
    end)
  end

  describe "a fix-pass subordinate that exits without `arb done`" do
    setup %{ws: ws, task: task} do
      pid =
        start_worker(ws, task,
          registry_key: task.id <> ":fixpass",
          meta: %{role: :fix_pass, target_branch: "main"}
        )

      state = exit_zero_without_done(pid, "sub-fixpass")
      {:ok, pid: pid, state: state}
    end

    test "the stop is still classified and recorded on the subordinate", %{state: state} do
      assert state.meta.stop_reason.category == :exited_without_done
      assert state.meta.stop_reason.exit_status == 0
    end

    test "does not raise a task-keyed worker_failed event", %{task: task} do
      # The Conductor pauses a member's downstream branch on this event, and the
      # API event stream reports it as the task's worker stopping. Neither is
      # true here: the task's own worker is untouched.
      task_id = task.id
      refute_receive {:event, %{topic: "worker_failed", task_id: ^task_id}}, 800
    end

    test "escalates as the fix pass, not as the task's own worker", %{ws: ws, task: task} do
      escalation = escalation_for(ws, task)

      assert escalation.subject =~ "fix pass",
             "subject must name the subordinate role, got: #{escalation.subject}"

      assert escalation.body =~ task.id <> ":fixpass",
             "body must name the subordinate's registry key so the operator can tell " <>
               "the two rows for this task_id apart, got:\n#{escalation.body}"
    end

    test "never advises resuming the task's primary worker", %{ws: ws, task: task} do
      escalation = escalation_for(ws, task)

      # This hint is what drove the reported stop+resume loop: `arb worker
      # resume <task_id>` is refused while the primary is parked at
      # :awaiting_review, so the operator stops the healthy primary instead.
      refute escalation.body =~ "arb worker resume #{task.id}",
             "escalation must not tell the coordinator to resume the task's primary " <>
               "worker, got:\n#{escalation.body}"

      # Nor may it fall back to the generic "re-dispatch" remediation, which
      # would re-dispatch the task itself — the same harm by another verb.
      refute escalation.body =~ "Remediation:",
             "escalation must not carry the generic re-dispatch remediation, " <>
               "got:\n#{escalation.body}"

      assert escalation.body =~ "unaffected"
    end

    test "exposes registry_key + role so two rows for one task_id are legible", %{
      ws: ws,
      task: task
    } do
      snap =
        Worker.list_children()
        |> Enum.find(&(&1.workspace_id == ws.id and &1[:registry_key] == task.id <> ":fixpass"))

      assert snap, "worker_list must expose registry_key to distinguish subordinate rows"
      assert snap[:role] == :fix_pass
      assert snap.task_id == task.id
    end
  end

  describe "the conflict-resolver subordinate" do
    test "is attributed to the conflict resolution pass, not the task", %{ws: ws, task: task} do
      pid =
        start_worker(ws, task,
          registry_key: task.id <> ":conflict",
          meta: %{role: :conflict_resolver}
        )

      exit_zero_without_done(pid, "sub-conflict")
      task_id = task.id

      refute_receive {:event, %{topic: "worker_failed", task_id: ^task_id}}, 800

      escalation = escalation_for(ws, task)
      assert escalation.subject =~ "conflict resolution pass"
      assert escalation.body =~ task.id <> ":conflict"
      refute escalation.body =~ "arb worker resume #{task.id}"
    end
  end

  describe "the task's own primary worker (control)" do
    test "still broadcasts worker_failed and still gets the resume hint", %{
      ws: ws,
      task: task
    } do
      pid = start_worker(ws, task, [])
      state = exit_zero_without_done(pid, "sub-primary")
      task_id = task.id

      assert state.meta.stop_reason.category == :exited_without_done
      assert_receive {:event, %{topic: "worker_failed", task_id: ^task_id}}, 1_000

      escalation = escalation_for(ws, task)
      assert escalation.subject =~ task.id
      assert escalation.body =~ "arb worker resume #{task.id}"
    end
  end
end
