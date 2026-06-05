defmodule ArbiterWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Resolve the running git SHA at boot so /api/version always reflects
    # the currently-checked-out commit, not a stale compile-time value.
    Application.put_env(:arbiter_web, :runtime_git_sha, resolve_git_sha())

    children = [
      ArbiterWeb.Telemetry,
      # Start a worker by calling: ArbiterWeb.Worker.start_link(arg)
      # {ArbiterWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      ArbiterWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ArbiterWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp resolve_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ArbiterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
