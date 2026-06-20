defmodule Arbiter.Workflows.MergeQueueSupervisorTest do
  # async: false — the MergeQueueSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueueSupervisor

  # Make every merge_queue this test starts use a no-op tick schedule, since the
  # supervisor's default opts come straight from MergeQueue.start_link/1.
  defp start_for_test(workspace_id, opts \\ []) do
    opts = Keyword.merge([auto_tick: false, repo: "octo/widget"], opts)

    {:ok, pid} = MergeQueueSupervisor.start_merge_queue(workspace_id, opts)

    # Allow the GenServer to talk to the Ecto sandbox the test owns.
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(MergeQueueSupervisor, pid)
    end)

    pid
  end

  describe "start_merge_queue/2" do
    test "starts a MergeQueue under the DynamicSupervisor and registers it" do
      ws_id = "ws-#{System.unique_integer([:positive])}"

      pid = start_for_test(ws_id)

      assert Process.alive?(pid)
      assert MergeQueueSupervisor.whereis(ws_id) == pid
    end

    test "duplicate starts for the same workspace return :already_started" do
      ws_id = "ws-#{System.unique_integer([:positive])}"
      pid = start_for_test(ws_id)

      assert {:error, {:already_started, ^pid}} =
               MergeQueueSupervisor.start_merge_queue(ws_id, auto_tick: false, repo: "octo/widget")
    end

    test "whereis/1 returns nil for an unknown workspace" do
      assert MergeQueueSupervisor.whereis("ws-nope-#{System.unique_integer([:positive])}") == nil
    end
  end

  describe "start_for_existing_workspaces/0" do
    test "starts a MergeQueue for every workspace in the database" do
      {:ok, ws_a} =
        Ash.create(Workspace, %{
          name: "ws-a-#{System.unique_integer([:positive])}",
          prefix: "rsa#{System.unique_integer([:positive])}"
        })

      {:ok, ws_b} =
        Ash.create(Workspace, %{
          name: "ws-b-#{System.unique_integer([:positive])}",
          prefix: "rsb#{System.unique_integer([:positive])}"
        })

      # In test, the workspace `:create` hook does not auto-start — so neither
      # ws_a nor ws_b has a MergeQueue yet.
      assert MergeQueueSupervisor.whereis(ws_a.id) == nil
      assert MergeQueueSupervisor.whereis(ws_b.id) == nil

      # Allow the boot Task (spawned indirectly via the DynamicSupervisor) to
      # reach the test's sandboxed Repo. Easiest: just call the function
      # synchronously here — it's what the boot Task would have done.
      :ok = MergeQueueSupervisor.start_for_existing_workspaces()

      pid_a = MergeQueueSupervisor.whereis(ws_a.id)
      pid_b = MergeQueueSupervisor.whereis(ws_b.id)
      assert is_pid(pid_a) and Process.alive?(pid_a)
      assert is_pid(pid_b) and Process.alive?(pid_b)

      on_exit(fn ->
        for pid <- [pid_a, pid_b], is_pid(pid) and Process.alive?(pid) do
          DynamicSupervisor.terminate_child(MergeQueueSupervisor, pid)
        end
      end)
    end
  end

  describe "workspace :create after_action hook" do
    test "starts a MergeQueue for a newly created workspace when auto_start is enabled" do
      # Flip the config flag for this test so the after_action change actually
      # fires. Restore it afterwards to keep the rest of the suite stable.
      original = Application.get_env(:arbiter, :auto_start_refineries, true)
      Application.put_env(:arbiter, :auto_start_refineries, true)
      on_exit(fn -> Application.put_env(:arbiter, :auto_start_refineries, original) end)

      ws_name = "ws-hook-#{System.unique_integer([:positive])}"
      ws_prefix = "rh#{System.unique_integer([:positive])}"

      {:ok, ws} = Ash.create(Workspace, %{name: ws_name, prefix: ws_prefix})

      pid = MergeQueueSupervisor.whereis(ws.id)
      assert is_pid(pid) and Process.alive?(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(MergeQueueSupervisor, pid)
      end)
    end

    test "does NOT start a MergeQueue when auto_start is disabled (default in test)" do
      ws_name = "ws-noauto-#{System.unique_integer([:positive])}"
      ws_prefix = "rn#{System.unique_integer([:positive])}"

      {:ok, ws} = Ash.create(Workspace, %{name: ws_name, prefix: ws_prefix})

      assert MergeQueueSupervisor.whereis(ws.id) == nil
    end
  end
end
