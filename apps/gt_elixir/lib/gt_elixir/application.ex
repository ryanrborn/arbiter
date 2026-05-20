defmodule GtElixir.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GtElixir.Repo,
      {DNSCluster, query: Application.get_env(:gt_elixir, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GtElixir.PubSub},
      {Registry, keys: :unique, name: GtElixir.Polecat.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: GtElixir.Polecat.Supervisor},
      {Registry, keys: :unique, name: GtElixir.Workflows.MachineRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: GtElixir.Workflows.MachineSupervisor}
      # Start a worker by calling: GtElixir.Worker.start_link(arg)
      # {GtElixir.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GtElixir.Supervisor)
  end
end
