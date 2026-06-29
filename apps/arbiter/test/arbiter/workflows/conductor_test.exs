defmodule Arbiter.Workflows.ConductorTest do
  # async: false — the Conductor runs in its own process and reads the DB; the
  # DataCase sandbox is shared (not async) so that process can see committed
  # rows, and the "tasks" PubSub topic is global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorSupervisor

  # Records every dispatch to the pid stashed in application env (mirrors the
  # MergeQueue tests' RecordingResolver). Returns {:ok, _} without spawning a
  # real worker. Leaves the dispatched issue :open so readiness is driven
  # explicitly by the test via close actions.
  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_conductor_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :test_conductor_pid, self())

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "conductor-ws-#{System.unique_integer([:positive])}",
        prefix: "cnd#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      Application.delete_env(:arbiter, :test_conductor_pid)
    end)

    %{ws: ws}
  end

  # ---- helpers ------------------------------------------------------------

  defp issue(ws, opts \\ []) do
    title = Keyword.get(opts, :title, "issue-#{System.unique_integer([:positive])}")
    {:ok, i} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    i
  end

  defp graph(ws) do
    {:ok, g} =
      Ash.create(Graph, %{name: "g-#{System.unique_integer([:positive])}", workspace_id: ws.id})

    g
  end

  defp add_member(graph, issue) do
    {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: issue.id})
    :ok
  end

  defp dep(from, to, type) do
    {:ok, _} =
      Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: type})

    :ok
  end

  defp close(issue) do
    {:ok, closed} = Ash.update(issue, %{reason: "test close"}, action: :close)
    closed
  end

  # Kick off and ensure the conductor is torn down at test end.
  defp kickoff(graph, opts \\ []) do
    opts = Keyword.put_new(opts, :dispatcher, RecordingDispatcher)
    {:ok, pid} = Conductor.kickoff(graph.id, opts)
    on_exit(fn -> ConductorSupervisor.stop_conductor(graph.id) end)
    pid
  end

  alias Arbiter.Messages.Message

  # Broadcast a worker_failed event on the workspace's events topic, simulating
  # what `Arbiter.Worker.broadcast_worker_failed/1` does in production.
  defp simulate_failure(issue, ws) do
    Arbiter.Events.broadcast(ws.id, "worker_failed", %{task_id: issue.id})
    # Allow the Conductor's handle_info to process before assertions.
    Process.sleep(50)
  end

  # Drain the Admiral inbox for a workspace and return unread escalations.
  defp admiral_inbox(ws) do
    Message.inbox("admiral", workspace_id: ws.id)
  end

  # ---- acyclicity validation ----------------------------------------------

  describe "validate_acyclic/1" do
    test "a linear chain is acyclic", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # a depends_on b — a single forward edge, no cycle.
      dep(a, b, :depends_on)

      assert :ok = Conductor.validate_acyclic(g.id)
    end

    test "a 2-node depends_on cycle is detected and named", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(a, b, :depends_on)
      dep(b, a, :depends_on)

      assert {:error, {:cyclic, cycle}} = Conductor.validate_acyclic(g.id)
      # Closed walk naming both offenders.
      assert a.id in cycle
      assert b.id in cycle
      assert List.first(cycle) == List.last(cycle)
    end

    test "a 3-node cycle across blocks + depends_on is detected", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      c = issue(ws)
      g = graph(ws)
      Enum.each([a, b, c], &add_member(g, &1))
      # a → b (a depends_on b), b → c (b depends_on c), c → a (a blocks c ⇒ edge c→a).
      dep(a, b, :depends_on)
      dep(b, c, :depends_on)
      dep(a, c, :blocks)

      assert {:error, {:cyclic, cycle}} = Conductor.validate_acyclic(g.id)
      assert a.id in cycle
      assert b.id in cycle
      assert c.id in cycle
    end

    test "conflicts_with is excluded from the cycle check", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # a depends_on b is a single forward edge. conflicts_with, if it were
      # treated as an ordering edge, would close the loop — but it must NOT.
      dep(a, b, :depends_on)
      dep(a, b, :conflicts_with)

      assert :ok = Conductor.validate_acyclic(g.id)
    end

    test "edges to non-members do not count", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      outsider = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # A cycle that runs through a non-member is not a cycle *within the graph*.
      dep(a, outsider, :depends_on)
      dep(outsider, a, :depends_on)

      assert :ok = Conductor.validate_acyclic(g.id)
    end
  end

  # ---- kickoff -------------------------------------------------------------

  describe "kickoff/2" do
    test "refuses a cyclic graph, names the cycle, and leaves it in :draft", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(a, b, :depends_on)
      dep(b, a, :depends_on)

      assert {:error, {:cyclic, cycle}} =
               Conductor.kickoff(g.id, dispatcher: RecordingDispatcher)

      assert a.id in cycle and b.id in cycle

      # No transition, no process.
      assert Ash.get!(Graph, g.id).run_state == :draft
      assert ConductorSupervisor.whereis(g.id) == nil
      refute_received {:dispatched, _, _}
    end

    test "refuses a non-draft graph", %{ws: ws} do
      g = graph(ws)
      {:ok, running} = Ash.update(g, %{run_state: :running})

      assert {:error, {:not_draft, :running}} =
               Conductor.kickoff(running.id, dispatcher: RecordingDispatcher)
    end

    test "returns :graph_not_found for an unknown graph" do
      assert {:error, :graph_not_found} =
               Conductor.kickoff(Ash.UUIDv7.generate(), dispatcher: RecordingDispatcher)
    end

    test "transitions draft → running and dispatches the initial ready set",
         %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g)

      assert_receive {:dispatched, dispatched_id, opts}
      assert dispatched_id == a.id
      # Operator-equivalent root dispatch depth.
      assert opts[:depth] == 0
      # Must dispatch a real agent, not the dry bookkeeping path.
      assert opts[:start_claude] == true
      assert Ash.get!(Graph, g.id).run_state == :running
    end
  end

  # ---- event-driven drain --------------------------------------------------

  describe "drain on close" do
    test "dispatches a directive once its gating blocker closes", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # b depends_on a — b is not ready until a closes.
      dep(b, a, :depends_on)

      kickoff(g)

      # Initial drain: only a is ready.
      assert_receive {:dispatched, a_id, _}
      assert a_id == a.id
      refute_receive {:dispatched, _, _}, 50

      # Close a → b becomes ready → drain dispatches b.
      close(a)

      assert_receive {:dispatched, b_id, _}
      assert b_id == b.id
    end

    test "ignores closes outside the graph's scope", %{ws: ws} do
      member = issue(ws)
      g = graph(ws)
      add_member(g, member)
      # An issue that is NOT a graph member.
      outsider = issue(ws)

      kickoff(g)

      assert_receive {:dispatched, member_id, _}
      assert member_id == member.id

      # Closing a non-member must not trigger another drain/dispatch.
      close(outsider)
      refute_receive {:dispatched, _, _}, 100
    end
  end

  # ---- conflicts_with serialization ----------------------------------------

  describe "conflicts_with serialization" do
    test "never co-dispatches two conflicting ready directives", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # Both ready (no gating deps), but mutually exclusive.
      dep(a, b, :conflicts_with)

      kickoff(g, max_concurrent: 5)

      # Exactly one of the pair is dispatched this pass.
      assert_receive {:dispatched, first_id, _}
      assert first_id in [a.id, b.id]
      refute_receive {:dispatched, _, _}, 100
    end

    test "honors a conflict regardless of stored edge direction", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # Edge stored b→a; symmetry must still serialize a vs b.
      dep(b, a, :conflicts_with)

      kickoff(g, max_concurrent: 5)

      assert_receive {:dispatched, _id, _}
      refute_receive {:dispatched, _, _}, 100
    end
  end

  # ---- effective cap (workspace × system × quota) -------------------------

  describe "effective concurrency cap" do
    test "dispatches no more than workspace_max_concurrent in a pass", %{ws: ws} do
      issues = for _ <- 1..3, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      # :max_concurrent is a backwards-compat alias for :workspace_max_concurrent.
      kickoff(g, max_concurrent: 2)

      assert_receive {:dispatched, id1, _}
      assert_receive {:dispatched, id2, _}
      refute_receive {:dispatched, _, _}, 100

      ids = MapSet.new([id1, id2])
      assert MapSet.size(ids) == 2
      assert MapSet.subset?(ids, MapSet.new(Enum.map(issues, & &1.id)))
    end

    test "system_max_concurrent caps when smaller than workspace max", %{ws: ws} do
      issues = for _ <- 1..4, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      # workspace allows 4, but system allows only 2 → effective cap = 2
      kickoff(g, workspace_max_concurrent: 4, system_max_concurrent: 2)

      assert_receive {:dispatched, _id1, _}
      assert_receive {:dispatched, _id2, _}
      refute_receive {:dispatched, _, _}, 100
    end

    test "workspace_max_concurrent caps when smaller than system max", %{ws: ws} do
      issues = for _ <- 1..4, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      # system allows 10, workspace allows only 1 → effective cap = 1
      kickoff(g, workspace_max_concurrent: 1, system_max_concurrent: 10)

      assert_receive {:dispatched, _id, _}
      refute_receive {:dispatched, _, _}, 100
    end

    test "workspace config max_concurrent is read at init", %{ws: ws} do
      # Set max_concurrent in the workspace config JSON blob.
      {:ok, ws} =
        Ash.update(ws, %{config: Map.put(ws.config, "conductor", %{"max_concurrent" => 1})})

      issues = for _ <- 1..3, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      # No explicit opt — resolved from workspace config (1), system max = 16
      kickoff(g)

      assert_receive {:dispatched, _id, _}
      refute_receive {:dispatched, _, _}, 100
    end
  end

  # ---- quota gate ----------------------------------------------------------

  describe "quota gate" do
    # A gate that always holds — used to assert no dispatch happens.
    defmodule HoldGate do
      @behaviour Arbiter.Workflows.QuotaGate
      @impl true
      def quota_headroom(_workspace_id), do: 0
    end

    # A gate that returns a fixed partial headroom — used to assert the min
    # formula correctly limits slots when quota < workspace cap.
    defmodule PartialGate do
      @behaviour Arbiter.Workflows.QuotaGate
      @impl true
      def quota_headroom(_workspace_id), do: 1
    end

    # A gate that always allows — baseline for "quota imposes no restriction".
    defmodule UnlimitedGate do
      @behaviour Arbiter.Workflows.QuotaGate
      @impl true
      def quota_headroom(_workspace_id), do: :unlimited
    end

    test "quota hold (headroom = 0) prevents all dispatch", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)

      kickoff(g, quota_gate: HoldGate, workspace_max_concurrent: 5)

      refute_receive {:dispatched, _, _}, 100
    end

    test "quota hold does not transition graph to :drained", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g, quota_gate: HoldGate)

      refute_receive {:dispatched, _, _}, 100
      assert Ash.get!(Graph, g.id).run_state == :running
    end

    test "partial headroom caps dispatch below the workspace max", %{ws: ws} do
      issues = for _ <- 1..3, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      # workspace_max = 3, quota headroom = 1 → effective cap = min(3, 1) = 1
      kickoff(g, quota_gate: PartialGate, workspace_max_concurrent: 3)

      assert_receive {:dispatched, _id, _}
      refute_receive {:dispatched, _, _}, 100
    end

    test "unlimited quota gate imposes no extra restriction", %{ws: ws} do
      issues = for _ <- 1..3, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      kickoff(g, quota_gate: UnlimitedGate, workspace_max_concurrent: 3)

      assert_receive {:dispatched, _, _}
      assert_receive {:dispatched, _, _}
      assert_receive {:dispatched, _, _}
      refute_receive {:dispatched, _, _}, 50
    end

    test "Default gate allows dispatch when no quota snapshot exists", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      # No Quota row for this workspace → Default returns :unlimited → dispatch proceeds
      kickoff(g, quota_gate: Arbiter.Workflows.QuotaGate.Default)

      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id
    end

    test "Default gate holds when status_5h is not allowed", %{ws: ws} do
      {:ok, _quota} =
        Ash.create(Arbiter.Quota.AnthropicQuota, %{
          workspace_id: ws.id,
          utilization_5h: 0.50,
          status_5h: "restricted",
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g, quota_gate: Arbiter.Workflows.QuotaGate.Default)

      refute_receive {:dispatched, _, _}, 100
    end

    test "Default gate holds when utilization_5h exceeds ceiling", %{ws: ws} do
      {:ok, _quota} =
        Ash.create(Arbiter.Quota.AnthropicQuota, %{
          workspace_id: ws.id,
          utilization_5h: 0.90,
          status_5h: "allowed",
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      # Default ceiling is 0.85; 0.90 > 0.85 → hold
      kickoff(g, quota_gate: Arbiter.Workflows.QuotaGate.Default)

      refute_receive {:dispatched, _, _}, 100
    end

    test "Default gate allows dispatch when utilization_5h is below ceiling", %{ws: ws} do
      {:ok, _quota} =
        Ash.create(Arbiter.Quota.AnthropicQuota, %{
          workspace_id: ws.id,
          utilization_5h: 0.70,
          status_5h: "allowed",
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g, quota_gate: Arbiter.Workflows.QuotaGate.Default)

      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id
    end
  end

  # ---- completion -----------------------------------------------------------

  describe "completion" do
    test "transitions running → drained and stops once all members close",
         %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      pid = kickoff(g)
      ref = Process.monitor(pid)

      assert_receive {:dispatched, a_id, _}
      assert a_id == a.id

      close(a)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Ash.get!(Graph, g.id).run_state == :drained
      assert ConductorSupervisor.whereis(g.id) == nil
    end
  end

  # ---- C5: failure handling -----------------------------------------------

  describe "failure pauses downstream branch" do
    test "a failed member pauses only its downstream; independent branches continue",
         %{ws: ws} do
      # Graph: a → b (b depends on a), c (independent)
      a = issue(ws)
      b = issue(ws)
      c = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      add_member(g, c)
      dep(b, a, :depends_on)

      pid = kickoff(g, max_concurrent: 10)

      # Initial drain dispatches a and c (b is blocked by a).
      dispatched_ids =
        for _ <- 1..2, do: (assert_receive({:dispatched, id, _}); id)

      assert MapSet.new(dispatched_ids) == MapSet.new([a.id, c.id])
      refute_receive {:dispatched, _, _}, 50

      # Simulate a's worker failing.
      simulate_failure(a, ws)

      snap = Conductor.state(pid)
      assert MapSet.member?(snap.failed_ids, a.id)
      assert MapSet.member?(snap.paused_ids, b.id)
      refute MapSet.member?(snap.paused_ids, c.id)

      # Closing c triggers a drain — b must NOT be dispatched (paused).
      close(c)
      refute_receive {:dispatched, _, _}, 100
    end

    test "state snapshot includes failed_ids and paused_ids", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      pid = kickoff(g)

      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)

      snap = Conductor.state(pid)
      assert MapSet.member?(snap.failed_ids, a.id)
      assert MapSet.member?(snap.paused_ids, b.id)
    end

    test "transitively downstream nodes are all paused", %{ws: ws} do
      # a → b → c (linear chain)
      a = issue(ws)
      b = issue(ws)
      c = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      add_member(g, c)
      dep(b, a, :depends_on)
      dep(c, b, :depends_on)

      pid = kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)

      snap = Conductor.state(pid)
      assert MapSet.member?(snap.failed_ids, a.id)
      assert MapSet.member?(snap.paused_ids, b.id)
      assert MapSet.member?(snap.paused_ids, c.id)
    end

    test "graph stays running (not drained) while failed members remain", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g)
      assert_receive {:dispatched, _dispatched_id, _}

      simulate_failure(a, ws)

      # Graph should still be :running, not :drained.
      assert Ash.get!(Graph, g.id).run_state == :running
    end
  end

  # ---- C5: Admiral inbox escalation ----------------------------------------

  describe "Admiral inbox escalation on failure" do
    test "a failed member posts an :escalation to the Admiral inbox", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      # Ensure inbox is empty before failure.
      assert admiral_inbox(ws) == []

      simulate_failure(a, ws)

      escalations = admiral_inbox(ws)
      assert length(escalations) >= 1

      escalation = Enum.find(escalations, &(&1.directive_ref == a.id))
      assert escalation != nil
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == a.id
      # The body should mention how to resume.
      assert String.contains?(escalation.body, "queue resume")
    end

    test "escalation mentions paused downstream tasks", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)

      [escalation | _] = admiral_inbox(ws)
      assert String.contains?(escalation.body, b.id)
    end
  end

  # ---- C5: resume ----------------------------------------------------------

  describe "resume continues the drain" do
    test "resume/2 re-dispatches the failed task and unpauses downstream", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      pid = kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)
      snap = Conductor.state(pid)
      assert MapSet.member?(snap.failed_ids, a.id)
      assert MapSet.member?(snap.paused_ids, b.id)

      # Resume clears the failed state and re-dispatches a.
      assert :ok = Conductor.resume(pid, a.id)

      assert_receive {:dispatched, redispatched_id, _}
      assert redispatched_id == a.id

      snap2 = Conductor.state(pid)
      refute MapSet.member?(snap2.failed_ids, a.id)
      refute MapSet.member?(snap2.paused_ids, b.id)
    end

    test "after resume, closing the re-dispatched task unblocks downstream", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      pid = kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)
      :ok = Conductor.resume(pid, a.id)

      # Consume the re-dispatch of a.
      assert_receive {:dispatched, redispatched_id, _}
      assert redispatched_id == a.id

      # Close a — b should now become ready and be dispatched.
      close(a)
      assert_receive {:dispatched, b_dispatched_id, _}
      assert b_dispatched_id == b.id
    end

    test "resume returns :not_failed for a task that has not failed", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      pid = kickoff(g)
      assert_receive {:dispatched, _, _}

      assert {:error, :not_failed} = Conductor.resume(pid, a.id)
    end

    test "resume returns :not_member for a task outside the graph", %{ws: ws} do
      a = issue(ws)
      outsider = issue(ws)
      g = graph(ws)
      add_member(g, a)

      pid = kickoff(g)
      assert_receive {:dispatched, _, _}

      assert {:error, :not_member} = Conductor.resume(pid, outsider.id)
    end

    test "resume_task/1 finds the conductor automatically", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(b, a, :depends_on)

      kickoff(g)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      simulate_failure(a, ws)

      assert :ok = Conductor.resume_task(a.id)
      assert_receive {:dispatched, redispatched_id, _}
      assert redispatched_id == a.id
    end

    test "resume_task/1 returns :not_found when no conductor has the task failed", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g)
      assert_receive {:dispatched, _, _}

      # a has not failed — not_found because no conductor has it in failed_ids.
      assert {:error, :not_found} = Conductor.resume_task(a.id)
    end
  end

  # ---- C6: live-worker exclusion (no double-dispatch across a restart) ------

  describe "live-worker exclusion" do
    test "a ready task with a live worker is NOT dispatched", %{ws: ws} do
      # Simulates the boot/restart window where a worker is already alive for a
      # task whose Issue is still :open — the drain must not re-dispatch it.
      claimed = issue(ws)
      free = issue(ws)
      g = graph(ws)
      add_member(g, claimed)
      add_member(g, free)

      # `claimed` is reported as having a live worker; `free` is idle.
      kickoff(g, worker_live?: fn id -> id == claimed.id end)

      # Only the un-claimed task is dispatched.
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == free.id
      refute_receive {:dispatched, _, _}, 50
    end

    test "once the live worker clears, the task is dispatched on the next drain", %{ws: ws} do
      # Flip liveness off after the first drain to prove the guard is dynamic and
      # the previously-claimed task isn't lost — it dispatches once idle.
      {:ok, agent} = Agent.start_link(fn -> true end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      claimed = issue(ws)
      g = graph(ws)
      add_member(g, claimed)

      pid = kickoff(g, worker_live?: fn _id -> Agent.get(agent, & &1) end)

      # First drain: worker is "live" → nothing dispatched.
      refute_receive {:dispatched, _, _}, 50

      # Worker clears; a manual drain now dispatches the task.
      Agent.update(agent, fn _ -> false end)
      assert [dispatched_id] = Conductor.drain(pid)
      assert dispatched_id == claimed.id
      assert_receive {:dispatched, ^dispatched_id, _}
    end
  end
end
