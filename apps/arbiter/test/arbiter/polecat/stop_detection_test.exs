defmodule Arbiter.Polecat.StopDetectionTest do
  # Detection of stopped/dead acolytes (bd-awi4nw). Drives a real port through a
  # polecat with commands that exit non-zero / print auth-failure / get killed,
  # and asserts the polecat flips OUT of a live state into :failed with a
  # classified stop reason — and that a normal `arb done` completion is NOT
  # misclassified as a stop.
  #
  # async: false — Port + Polecat registry are global; DataCase gives the DB
  # sandbox the Admiral escalation write needs.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat

  @fixture Path.expand("../../fixtures/echo_with_done.sh", __DIR__)

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "stop-detect-ws", prefix: "sd"})
    {:ok, ws: ws}
  end

  defp start_polecat(ws) do
    {:ok, bead} = Ash.create(Issue, %{title: "detect my death", workspace_id: ws.id})

    {:ok, pid} =
      Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    {pid, bead}
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
      case Polecat.state(pid) do
        %{status: :failed} = s -> s
        _ -> nil
      end
    end)
  end

  describe "subprocess exit while running → fail + classify" do
    test "non-zero crash flips the polecat to :failed with a stop reason", %{ws: ws} do
      {pid, _bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-crash")

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
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
      {pid, _bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-credit")

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo 'Your credit balance is too low'; exit 1"]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :credit_exhausted
    end

    test "simulated auth expiry (401) is classified as :auth_expired", %{ws: ws} do
      {pid, _bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-auth")

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
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
      {pid, _bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-kill")

      # The shell kills ITSELF with SIGKILL; the sh wrapper surfaces 128+9=137.
      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo working; kill -9 $$"]
        )

      state = wait_for_failed(pid)
      assert state.meta.stop_reason.category == :killed
      assert state.meta.stop_reason.signal == 9
    end

    test "an Admiral escalation is raised naming the bead + cause", %{ws: ws} do
      {pid, bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-escalate")

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo '401 invalid authentication credentials'; exit 1"]
        )

      wait_for_failed(pid)

      escalation =
        eventually(fn ->
          Message.inbox("admiral", workspace_id: ws.id)
          |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == bead.id))
        end)

      assert escalation.subject =~ bead.id
      assert escalation.subject =~ "credentials expired"
      assert escalation.body =~ "Remediation:"
      assert escalation.body =~ "Re-authenticate"
    end
  end

  describe "normal completion is not misclassified as a stop" do
    test "the arb-done fixture completes, never fails", %{ws: ws} do
      {pid, _bead} = start_polecat(ws)
      :ok = Polecat.advance(pid, :claude)
      cwd = tmp_dir!("sd-done")

      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture]
        )

      # The fixture prints "arb done" then exits 0. The done signal must win the
      # race against the exit, so the deferred stop-check no-ops.
      status =
        eventually(fn ->
          case Polecat.state(pid).status do
            :completed -> :completed
            _ -> nil
          end
        end)

      assert status == :completed
      # Give the deferred stop-check time to (not) fire.
      Process.sleep(120)
      refute Polecat.state(pid).status == :failed
    end
  end
end
