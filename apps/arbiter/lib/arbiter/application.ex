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
      Arbiter.Agents.ProviderPool,
      Arbiter.Agents.CredentialWarden,
      {Registry, keys: :unique, name: Arbiter.Polecat.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Polecat.Supervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Polecat.WardenSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.MachineRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Workflows.MachineSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.RefineryRegistry},
      RefinerySupervisor
    ] ++ boot_tasks(auto_start?)
  end

  # The gated boot children. The two `Task` children each MUST carry a distinct
  # explicit `:id` — without one they both collapse to the default `:Task` id
  # and the whole app fails to boot ("more than one child specification has the
  # id: Task").
  #
  #   * SingleInstance: hold a session advisory lock that identifies the one
  #     canonical instance per DB. Started FIRST (and synchronously, via its
  #     init) so the migrator and reconcile Task below can read its verdict.
  #     See bd-9rouwh.
  #   * migrator: run pending Ecto migrations to head, SYNCHRONOUSLY, before any
  #     later child (or the :arbiter_web endpoint) comes up against a stale
  #     schema. Gated on the SingleInstance primary verdict so only the one
  #     canonical instance migrates. A migration failure aborts the boot. Placed
  #     before reconcile/refinery so those run against the current schema. It is
  #     a one-shot worker (returns :ignore), not a Task, precisely so it BLOCKS
  #     the boot until the schema is current. See Arbiter.Boot.Migrator.
  #   * reconcile: sweep orphaned :running polecat_runs left behind by a node
  #     that died mid-run. Runs once after Repo + Polecat.Registry are online —
  #     but ONLY on the primary instance, so a transient/duplicate boot can't
  #     fail the live instance's running runs.
  #   * reconcile_open_prs: find :in_progress beads with a pr_ref but no live
  #     polecat — the server was killed between `arb done` and the Warden being
  #     established. Escalates each to Admiral. bd-crqku8.
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
      Arbiter.SingleInstance,
      Arbiter.Boot.Migrator,
      Supervisor.child_spec(
        {Task,
         fn ->
           primary? = Arbiter.SingleInstance.primary?()
           Arbiter.Polecats.Reconciler.reconcile_orphaned_runs(primary?: primary?)
           Arbiter.Polecats.Reconciler.reconcile_open_pr_beads(primary?: primary?)
         end},
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
