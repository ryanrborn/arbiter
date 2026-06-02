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

  `:auto_start?` controls whether the gated boot Tasks (orphan-run
  reconciliation and refinery enumeration) are appended. `start/2` mirrors
  `RefinerySupervisor.auto_start?()` here — false in `test`, true everywhere
  else — so the boot Tasks don't race the sandboxed DB connection.

  This is a pure function (it builds specs, it starts nothing) so a test can
  resolve the *full* boot wiring with `auto_start?: true` and assert every
  child id is unique. That guard matters because the boot Tasks are gated off
  in test: a duplicate child id between them is otherwise invisible to the
  green suite and only surfaces as a real dev/prod boot crash ("more than one
  child specification has the id: Task"). See `Arbiter.ApplicationTest`.
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

  # The gated boot Tasks. Both are `Task` children, so each MUST carry a
  # distinct explicit `:id` — without one they both collapse to the default
  # `:Task` id and the whole app fails to boot ("more than one child
  # specification has the id: Task").
  #
  #   * reconcile: sweep orphaned :running polecat_runs left behind by a node
  #     that died mid-run. Runs once after Repo + Polecat.Registry are online.
  #   * refinery: eagerly start one Refinery per existing workspace once the
  #     tree is up, so a cold boot misses no `:polecat_done` events.
  #
  # Gated off in test (auto_start?/0 is false) so the boot sweep doesn't race
  # the sandboxed connection and test code can drive the GenServers with its
  # own stubs. That gating is exactly why an id collision here is invisible to
  # the suite — `Arbiter.ApplicationTest` forces `auto_start?: true` to close
  # the gap.
  defp boot_tasks(false), do: []

  defp boot_tasks(true) do
    [
      Supervisor.child_spec(
        {Task, fn -> Arbiter.Polecats.Reconciler.reconcile_orphaned_runs() end},
        id: :reconcile_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> RefinerySupervisor.start_for_existing_workspaces() end},
        id: :refinery_boot_task,
        restart: :temporary
      )
    ]
  end
end
