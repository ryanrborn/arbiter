defmodule Arbiter.Worker.StopDetectionTest do
  # Detection of stopped/dead workers (bd-awi4nw). Drives a real port through a
  # worker with commands that exit non-zero / print auth-failure / get killed,
  # and asserts the worker flips OUT of a live state into :failed with a
  # classified stop reason — and that a normal `arb done` completion is NOT
  # misclassified as a stop.
  #
  # async: false — Port + Worker registry are global; DataCase gives the DB
  # sandbox the Coordinator escalation write needs.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  @fixture Path.expand("../../fixtures/echo_with_done.sh", __DIR__)

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "stop-detect-ws", prefix: "sd"})
    {:ok, ws: ws}
  end

  defp start_worker(ws) do
    {:ok, task} = Ash.create(Issue, %{title: "detect my death", workspace_id: ws.id})

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, task}
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp eventually(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
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

  defp wait_for_failed(pid) do
    eventually(fn ->
      case Worker.state(pid) do
        %{status: :failed} = s -> s
        _ -> nil
      end
    end)
  end

  describe "subprocess exit while running → fail + classify" do
    test "non-zero crash flips the worker to :failed with a stop reason", %{ws: ws} do
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-crash")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo 'error: unknown option --reasoning-effort'; exit 1"]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :crashed
      assert state.meta.stop_reason.exit_status == 1
      assert is_binary(state.meta.failure_reason)
    end

    test "simulated credit exhaustion is classified as :credit_exhausted", %{ws: ws} do
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-credit")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo 'Your credit balance is too low'; exit 1"]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :credit_exhausted
    end

    test "simulated auth expiry (401) is classified as :auth_expired", %{ws: ws} do
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-auth")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [
            "sh",
            "-c",
            "echo 'API Error: 401 Invalid authentication credentials'; exit 1"
          ]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :auth_expired
    end

    test "a killed subprocess is classified as :killed", %{ws: ws} do
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-kill")

      # The shell kills ITSELF with SIGKILL; the sh wrapper surfaces 128+9=137.
      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo working; kill -9 $$"]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :killed
      assert state.meta.stop_reason.signal == 9
    end

    test "an Coordinator escalation is raised naming the task + cause", %{ws: ws} do
      {pid, task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-escalate")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo '401 invalid authentication credentials'; exit 1"]
        )

      wait_for_failed(pid)

      escalation =
        eventually(fn ->
          Message.inbox("coordinator", workspace_id: ws.id)
          |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))
        end)

      assert escalation.subject =~ task.id
      assert escalation.subject =~ "credentials expired"
      assert escalation.body =~ "Remediation:"
      assert escalation.body =~ "Re-authenticate"
    end
  end

  describe "normal completion is not misclassified as a stop" do
    test "the arb-done fixture completes, never fails", %{ws: ws} do
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-done")

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture]
        )

      # The fixture prints "arb done" then exits 0. The done signal must win the
      # race against the exit, so the deferred stop-check no-ops.
      status =
        eventually(fn ->
          case Worker.state(pid).status do
            :completed -> :completed
            _ -> nil
          end
        end)

      assert status == :completed
      # Give the deferred stop-check time to (not) fire.
      Process.sleep(120)
      refute Worker.state(pid).status == :failed
    end
  end

  describe "arb done in a resume/continuation session (bd-1pdyov)" do
    test "a continuation session that prints arb done after the primary exits completes, not fails",
         %{ws: ws} do
      # Incident bd-53xrmi: the primary session ended (port exit, status 0)
      # WITHOUT the marker — it spent its final turns cleaning a dirty .mcp.json
      # — while a short continuation session (the commit-gate nudge respawn) was
      # still mid-run. The primary's deferred stop-check fired during the grace
      # window and falsely marked committed work :failed before the continuation
      # printed `arb done`.
      #
      # Here we reproduce the SHAPE of that race with two real session ports on
      # one worker:
      #   * primary  — exits 0 immediately, no marker.
      #   * continuation — stays alive past the exit grace, then prints `arb done`.
      # The whole-run stop check must see the continuation is still live, no-op,
      # and let the continuation drive completion.
      {pid, _task} = start_worker(ws)
      :ok = Worker.advance(pid, :claude)
      cwd = tmp_dir!("sd-continuation")

      # Primary: does its work and exits cleanly, never emitting the marker.
      {:ok, _primary} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo 'primary: tidied .mcp.json'; exit 0"]
        )

      # Continuation: outlives the @exit_grace_ms (500ms) window so the primary's
      # deferred stop-check fires while this one is still running, then signals.
      {:ok, _continuation} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "sleep 1; echo 'arb done'"]
        )

      status =
        eventually(
          fn ->
            case Worker.state(pid).status do
              :completed -> :completed
              _ -> nil
            end
          end,
          4_000
        )

      assert status == :completed
      state = Worker.state(pid)
      refute state.status == :failed
      # It completed via the marker, not by some other path: no stop reason was
      # ever recorded.
      refute Map.has_key?(state.meta, :stop_reason)
    end
  end
end
