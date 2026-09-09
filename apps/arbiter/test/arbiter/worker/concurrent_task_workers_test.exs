defmodule Arbiter.Worker.ConcurrentTaskWorkersTest do
  # bd-8tjcms / #1511 — a task must never have two *actively working* workers.
  #
  # `Arbiter.Worker` registers under a `:registry_key` that defaults to the
  # task_id, but the merge queue's subordinate passes deliberately take
  # `<task_id>:fixpass` / `<task_id>:conflict` so they can run alongside the
  # primary worker parked at `:awaiting_review` (bd-8lq2g7). Every "is a worker
  # already running for this task?" guard in `Arbiter.Worker.Dispatch` looks up
  # the *exact* task_id key via `Worker.whereis/1`, so it cannot see a
  # subordinate — and `FixPassDispatcher` / `ConflictResolver` only guard their
  # own key. The two families are therefore mutually invisible, which is how
  # vs-ehjarz ended up with two live agent sessions on one task and one branch.
  #
  # The rule enforced here: at most one worker per task may be in an *active*
  # (agent-bearing) status. Parked (`:awaiting_review*`) and terminal
  # (`:failed` / `:completed`) workers still allow a new pass to start — that
  # coexistence is the documented merge-queue design and must not regress.
  #
  # async: false — the Worker registry and DynamicSupervisor are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "concurrent-worker-ws", prefix: "cw"})
    {:ok, task} = Ash.create(Issue, %{title: "ship the thing", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  defp start_worker!(ws, task, opts) do
    opts = Keyword.merge([task_id: task.id, repo: "test/repo", workspace_id: ws.id], opts)
    {:ok, pid} = Worker.start(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp start_worker(ws, task, opts) do
    opts = Keyword.merge([task_id: task.id, repo: "test/repo", workspace_id: ws.id], opts)

    case Worker.start(opts) do
      {:ok, pid} = ok ->
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
        ok

      other ->
        other
    end
  end

  describe "active_status?/1" do
    test "classifies the FSM's agent-bearing statuses as active" do
      for status <- [:idle, :resuming, :running, :awaiting] do
        assert Worker.active_status?(status), "expected #{status} to be active"
      end
    end

    test "parked and terminal statuses are not active" do
      for status <- [:awaiting_review, :awaiting_review_gate, :completed, :failed] do
        refute Worker.active_status?(status), "expected #{status} to be inactive"
      end
    end
  end

  describe "a second live worker for one task" do
    test "a subordinate pass is refused while the primary is running", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:error, {:task_worker_live, info}} =
               start_worker(ws, task, registry_key: task.id <> ":fixpass")

      assert info.task_id == task.id
      assert info.registry_key == task.id
      assert info.status == :running
      assert info.pid == primary
      assert info.requested_key == task.id <> ":fixpass"
    end

    test "a primary dispatch is refused while a subordinate pass is running", %{
      ws: ws,
      task: task
    } do
      fixpass = start_worker!(ws, task, registry_key: task.id <> ":fixpass")
      :ok = Worker.advance(fixpass, :claude)

      assert {:error, {:task_worker_live, info}} = start_worker(ws, task, [])
      assert info.registry_key == task.id <> ":fixpass"
      assert info.status == :running
    end

    test "the same key still reports :already_started, not the new error", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:error, {:already_started, ^primary}} = start_worker(ws, task, [])
    end
  end

  describe "coexistence that must keep working" do
    test "a subordinate pass starts alongside a terminal primary", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)
      :ok = Worker.fail(primary, :some_failure)

      assert {:ok, pid} = start_worker(ws, task, registry_key: task.id <> ":fixpass")
      assert is_pid(pid)
    end

    test "a ReviewGate synthetic worker (# key) is never blocked", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      opts = [task_id: task.id <> "#review", repo: "test/repo", workspace_id: nil]
      assert {:ok, pid} = Worker.start(opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    end

    test "an explicit opt-out still starts a second worker", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:ok, pid} =
               start_worker(ws, task,
                 registry_key: task.id <> ":conflict",
                 allow_concurrent_task_worker: true
               )

      assert is_pid(pid)
    end
  end
end
