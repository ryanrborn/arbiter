defmodule Arbiter.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. SQLite with WAL mode
  supports concurrent readers, but the sandbox serializes writes;
  `async: true` is safe for read-only tests but may produce
  contention warnings under heavy parallel write load.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Arbiter.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Arbiter.DataCase
    end
  end

  setup tags do
    Arbiter.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Arbiter.Repo, shared: not tags[:async])

    # A whole family of VM-global `DynamicSupervisor`s (started once at
    # application boot — see `Arbiter.Application`) hold long-lived, per-workspace
    # worker/workflow GenServers: `Arbiter.Worker.Supervisor`,
    # `Arbiter.Worker.WatchdogSupervisor`, `Arbiter.Workflows.MachineSupervisor`,
    # `Arbiter.Workflows.MergeQueueSupervisor`, `Arbiter.Workflows.PRPatrolSupervisor`,
    # `Arbiter.Workflows.ReviewPatrolSupervisor`,
    # `Arbiter.Workflows.MergedPRFinalizerSupervisor`,
    # `Arbiter.Workflows.DispatchQueueSupervisor`, and
    # `Arbiter.Workflows.ConductorSupervisor`. Several other call paths
    # (`Arbiter.Workflows.DispatchQueue.spawn_drain/2`,
    # `Arbiter.Worker.Dispatch.maybe_verify_codex_mcp_connection/4`,
    # `Arbiter.Reviews.ExternalReview.start_async/3`, `Arbiter.Quota.RefreshProbe`,
    # `Arbiter.Quota.CloudProbe`, `Arbiter.GitHub.Limiter.start_task/2`)
    # deliberately fire a detached
    # `Task.Supervisor.start_child/2` under a VM-global Task.Supervisor. None
    # of these are per-test, so any of these processes a test forgot to stop,
    # or a detached Task the test has no handle on, can still be mid-write
    # when this test ends. If `on_exit` tore the sandbox connection down while
    # any of them was still using it, the single `pool_size: 1` SQLite
    # connection crashed ("owner ... exited" / "Client ... is still using a
    # connection from owner") and reconnected — and because that physical
    # connection is shared by literally every test in the suite, the reconnect
    # churn silently corrupted whichever *unrelated*, concurrently-queued
    # test's write landed in that window (bd-9j4znl) — e.g. `CoordinatorNotifier`'s
    # functions `rescue`/`catch` and return `:ok` regardless. This is why the
    # order-dependent-looking failures moved around between runs: it's not the
    # test order, it's which test happens to be mid-write when a leaked
    # process finally touches the connection after teardown.
    #
    # Stop every leaked per-workspace worker/workflow process and drain
    # in-flight detached Tasks — in that order, and strictly *before*
    # `stop_owner` — so nothing can still be using the connection when it goes
    # away. `on_exit` runs LIFO (most-recently-registered first), so register
    # `stop_owner` first here and the sweep after, even though the sweep must
    # visibly run first.
    on_exit(fn ->
      drain_task_supervisor(Arbiter.Workflows.DispatchDrainSupervisor)
      drain_task_supervisor(Arbiter.Worker.MCPVerifySupervisor)
      drain_task_supervisor(Arbiter.Reviews.TaskSupervisor)
      drain_task_supervisor(Arbiter.Quota.RefreshProbeSupervisor)
      drain_task_supervisor(Arbiter.Quota.CloudProbeSupervisor)
      drain_task_supervisor(Arbiter.TaskSupervisor)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    on_exit(&stop_leaked_dynamic_children/0)

    :ok
  end

  @leaked_dynamic_supervisors [
    Arbiter.Worker.Supervisor,
    Arbiter.Worker.WatchdogSupervisor,
    Arbiter.Workflows.MachineSupervisor,
    Arbiter.Workflows.MergeQueueSupervisor,
    Arbiter.Workflows.PRPatrolSupervisor,
    Arbiter.Workflows.ReviewPatrolSupervisor,
    Arbiter.Workflows.MergedPRFinalizerSupervisor,
    Arbiter.Workflows.DispatchQueueSupervisor,
    Arbiter.Workflows.ConductorSupervisor
  ]

  @doc false
  def stop_leaked_dynamic_children do
    Enum.each(@leaked_dynamic_supervisors, &stop_dynamic_supervisor_children/1)
  end

  # `DynamicSupervisor.terminate_child/2`, NOT `GenServer.stop/3`: some of
  # these children (`MergeQueue`, `DispatchQueue`, `MergedPRFinalizer`) have
  # no `child_spec/1` override and so default to `restart: :permanent`.
  # `GenServer.stop(pid, :normal, ...)` looks like a clean stop but is still
  # a supervised child exiting, so a `:permanent` child gets restarted
  # immediately by its DynamicSupervisor — and since the test's sandbox
  # owner is gone, the restarted process's `init` fails the same way,
  # crash-looping until the DynamicSupervisor exceeds its restart intensity
  # and takes itself (and eventually `Arbiter.Repo`, cascading up through
  # `Arbiter.Supervisor`) down with it. `terminate_child/2` removes the
  # child from the supervisor directly, so no restart is ever attempted
  # regardless of the child's `:restart` strategy.
  defp stop_dynamic_supervisor_children(supervisor) do
    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            try do
              DynamicSupervisor.terminate_child(supervisor, child_pid)
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end)

      nil ->
        :ok
    end
  end

  @doc false
  def drain_task_supervisor(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid
        |> Task.Supervisor.children()
        |> Enum.each(fn child_pid ->
          ref = Process.monitor(child_pid)

          receive do
            {:DOWN, ^ref, :process, ^child_pid, _reason} -> :ok
          after
            5_000 -> Process.demonitor(ref, [:flush])
          end
        end)

      nil ->
        :ok
    end
  end

  @doc """
  Set an `Application` env var for the rest of the current test, restoring
  whatever was there before (or clearing the key, if it was unset) on exit.

  Several tests used to `Application.put_env/3` a key like `:worktree_root`
  and unconditionally `Application.delete_env/2` it in `on_exit` — which
  looks like cleanup but actually clobbers config/test.exs's default with
  "unset" for whichever `async: false` test happens to run next in the sync
  phase. That's what made `Arbiter.Reviews.CheckoutTest` and friends look
  order-dependent: they only passed when scheduled after nothing had wiped
  the key (bd-9j4znl). Always capture-and-restore instead of blind delete.
  """
  def put_app_env(app, key, value) do
    prior = Application.get_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        nil -> Application.delete_env(app, key)
        v -> Application.put_env(app, key, v)
      end
    end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
