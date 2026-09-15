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
    # Registered before the sandbox owner so the matching `on_exit` runs last
    # (`on_exit` is LIFO): a connection killed by the teardown below still
    # gets attributed to this test. See `Arbiter.Test.SandboxMonitor`.
    test_pid = self()
    Arbiter.Test.SandboxMonitor.track(test_pid, tags[:module], tags[:test])
    on_exit(fn -> Arbiter.Test.SandboxMonitor.untrack(test_pid) end)

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
    # `Arbiter.Reviews.ExternalReview.start_async/3`,
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
      drain_task_supervisor(Arbiter.Quota.CloudProbeSupervisor)
      drain_task_supervisor(Arbiter.TaskSupervisor)
      settle_sandbox(pid)
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

  # Deliberately NOT here: `Arbiter.Sessions.Stream.Supervisor` (bd-3ymdvi).
  # This list exists for processes that can be mid-write on the shared sandbox
  # connection at teardown. A session reader never touches the database — it
  # reads a pipe file and sends messages — so it cannot corrupt the connection,
  # and it stops itself when the subscriber it monitors dies. Sweeping it here
  # would instead reach *into a concurrently running `async: true` test* and
  # kill the reader it is in the middle of asserting on.

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
  #
  # bd-5scl0c: `terminate_child/2` on its own is still not safe, because it
  # sends a bare `Process.exit(child, :shutdown)` and none of these children
  # trap exits — so the signal kills them the instant it arrives, including
  # mid-query, which drops the whole suite's single sandbox connection out
  # from under whoever owned it. `Arbiter.ProcessTeardown.stop_child/2`
  # quiesces the child with `:sys.suspend/2` first; its moduledoc has the
  # full mechanism.
  defp stop_dynamic_supervisor_children(supervisor) do
    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_, child_pid, _, _} when is_pid(child_pid) ->
            Arbiter.ProcessTeardown.stop_child(supervisor, child_pid)

          _ ->
            :ok
        end)

      nil ->
        :ok
    end
  end

  @doc """
  Make the sandbox connection finish processing the death of every client this
  test killed, before the connection is handed to the next test (bd-5scl0c).

  When a process dies while holding a checkout, it does not notify anybody:
  the BEAM gives its holder ETS table away, and
  `DBConnection.Ownership.Proxy` turns that `ETS-TRANSFER` into
  `client #PID<..> exited` and disconnects (`proxy.ex:153`). Erlang orders
  signals per sender/receiver *pair* only, so observing the client's death
  elsewhere — e.g. ExUnit waiting on the test supervisor's `:DOWN` before it
  runs `on_exit` — says nothing about whether the proxy has handled the
  give-away yet. Left alone, that disconnect regularly landed a few hundred
  microseconds into the *next* test, which by then owns the connection:
  measured over 5 full `apps/arbiter_web` runs, 7 disconnects landed mid-test
  without this barrier and 0 with it.

  One synchronous round-trip fixes the ordering without any waiting: a
  `gen_server` handles its mailbox in order, so by the time our query comes
  back, every `ETS-TRANSFER` already queued ahead of it has been processed and
  the disconnect (if any) has landed here, inside the owning test's teardown,
  where the connection is about to be handed back anyway.

  Everything is caught: the proxy may *already* have shut down over exactly
  such a transfer, and a teardown helper must never be the thing that fails a
  green test.
  """
  def settle_sandbox(owner) do
    # `on_exit` runs in its own process, which owns nothing; in shared mode the
    # allow is redundant, in `async: true` it is what makes the query legal.
    # Guarded separately from the query: an allow that fails (the owner may
    # already be gone) must not skip the round-trip that is the actual barrier.
    safely(fn -> Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, owner, self()) end)
    safely(fn -> Arbiter.Repo.query!("SELECT 1") end)
    :ok
  end

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
  Create an issue whose `repo` is `nil` — the shape every issue had before
  bd-9dwbvt, and the one the backfill and dispatch's late resolution still
  have to cope with.

  `:create` now binds a repo (`Arbiter.Tasks.Issue.Changes.ResolveRepo`), and
  in a multi-repo workspace with no `default_repo` it refuses to create at all
  without one. `:update` is deliberately not hooked, so this seeds with a
  configured repo (when the workspace has any) and then clears it — which is
  also exactly how an operator un-assigns a repo in production.

  Use this ONLY where the repo-less state is the thing under test. A test that
  just wants an issue should let `:create` resolve the repo normally.
  """
  def issue_without_repo!(attrs) when is_map(attrs) do
    ws_id = Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id")

    seed =
      case Arbiter.Tasks.IssueRepo.configured_repos(ws_id) do
        [] -> attrs
        [repo | _] -> Map.put(attrs, :repo, repo)
      end

    {:ok, issue} = Ash.create(Arbiter.Tasks.Issue, seed)
    {:ok, issue} = Ash.update(issue, %{repo: nil})
    issue
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
