defmodule Arbiter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbiter.Repo,
      {DNSCluster, query: Application.get_env(:arbiter, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Arbiter.PubSub},
      {Registry, keys: :unique, name: Arbiter.Polecat.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Polecat.Supervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.MachineRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Workflows.MachineSupervisor}
      # Start a worker by calling: Arbiter.Worker.start_link(arg)
      # {Arbiter.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbiter.Supervisor)
  end
end
