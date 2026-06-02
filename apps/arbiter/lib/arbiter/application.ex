defmodule Arbiter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Arbiter.Workflows.RefinerySupervisor

  @impl true
  def start(_type, _args) do
    children =
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
      ] ++ reconcile_boot_task() ++ refinery_boot_task()

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbiter.Supervisor)
  end

  # Reconcile orphaned :running polecat_runs left behind by a node that died
  # mid-run. Runs as a Task child once the Repo and Polecat.Registry are online.
  # Gated off in test (auto_start_refineries=false) so the app-boot sweep doesn't
  # race the sandboxed connection; tests call the reconciler directly instead.
  defp reconcile_boot_task do
    if RefinerySupervisor.auto_start?() do
      [{Task, fn -> Arbiter.Polecats.Reconciler.reconcile_orphaned_runs() end}]
    else
      []
    end
  end

  # Eagerly start one Refinery per existing workspace once the supervision
  # tree is up. A Task child runs after the RefinerySupervisor + Repo are
  # online; gated so test runs don't enumerate workspaces (test code starts
  # refineries explicitly with stubbed transport).
  defp refinery_boot_task do
    if RefinerySupervisor.auto_start?() do
      [{Task, fn -> RefinerySupervisor.start_for_existing_workspaces() end}]
    else
      []
    end
  end
end
