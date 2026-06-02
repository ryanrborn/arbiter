defmodule Arbiter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Arbiter.Workflows.RefinerySupervisor

  @impl true
  def start(_type, _args) do
    children = children(auto_start?: RefinerySupervisor.auto_start?())

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbiter.Supervisor)
  end

  @doc """
  Build the application's full child spec list.

  `:auto_start?` controls whether the gated boot children (the orphan-run
  reconcile guard and the refinery enumeration Task) are appended. `start/2`
  mirrors `RefinerySupervisor.auto_start?()` here — false in `test`, true
  everywhere else — so the boot children don't race the sandboxed DB
  connection.

  This is a pure function (it builds specs, it starts nothing) so a test can
  resolve the *full* boot wiring with `auto_start?: true` and assert every
  child id is unique. That guard matters because the boot children are gated
  off in test: a duplicate child id is otherwise invisible to the green suite
  and only surfaces as a real dev/prod boot crash ("more than one child
  specification has the id: Task"). See `Arbiter.ApplicationTest`.
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children(opts \\ []) do
    auto_start? = Keyword.get(opts, :auto_start?, RefinerySupervisor.auto_start?())

    [
      Arbiter.Repo,
      {DNSCluster, query: Application.get_env(:arbiter, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Arbiter.PubSub},
      {Registry, keys: :unique, name: Arbiter.Polecat.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Polecat.Supervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Polecat.WardenSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.MachineRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Workflows.MachineSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.RefineryRegistry},
      RefinerySupervisor
    ] ++ boot_tasks(auto_start?)
  end

  # The gated boot children, started once after Repo + Polecat.Registry:
  #
  #   * ReconcileGuard: a long-lived GenServer that acquires a single-instance
  #     Postgres advisory lock and — only if it wins — sweeps orphaned :running
  #     polecat_runs left behind by a canonical node that died mid-run. A
  #     transient second boot against the same DB loses the lock race and skips
  #     the sweep, so it can't fail the primary instance's live runs (bd-9rouwh).
  #     It must hold the lock for the node's lifetime, hence a GenServer, not a
  #     one-shot Task.
  #   * refinery_boot_task: eagerly start one Refinery per existing workspace
  #     once the tree is up, so a cold boot misses no `:polecat_done` events.
  #     A bare `{Task, fn}` defaults to the `:Task` child id, so it carries an
  #     explicit `:id` (the boot crash "more than one child specification has
  #     the id: Task" appears the moment a second bare Task is added without one).
  #
  # Gated off in test (auto_start?/0 is false) so the boot children don't race
  # the sandboxed connection and test code can drive the reconciler/guard with
  # its own stubs. That gating is exactly why an id collision here is invisible
  # to the suite — `Arbiter.ApplicationTest` forces `auto_start?: true` to close
  # the gap.
  defp boot_tasks(false), do: []

  defp boot_tasks(true) do
    [
      Arbiter.Polecats.ReconcileGuard,
      Supervisor.child_spec(
        {Task, fn -> RefinerySupervisor.start_for_existing_workspaces() end},
        id: :refinery_boot_task,
        restart: :temporary
      )
    ]
  end
end
