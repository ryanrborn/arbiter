defmodule ArbiterWeb.Plugs.CheckRepoStatusExceptMachineRoutes do
  @moduledoc """
  Wraps `Phoenix.Ecto.CheckRepoStatus` to skip machine-facing routes.

  `Phoenix.Ecto.CheckRepoStatus` renders a developer-facing HTML error when
  migrations are pending, which is only useful in front of a browser. Applied
  at the endpoint level (dev-only, inside `if code_reloading?`), it also
  guards every machine-to-machine path — the Anthropic proxy, the REST API,
  the MCP endpoint, the event stream — so a pending migration 503s in-flight
  workers instead of just showing a dashboard visitor a friendly error
  (bd-44gk10).

  Requests under `/proxy`, `/api`, `/events`, or `/mcp` pass straight
  through; everything else (browser/LiveView routes) still gets the check.
  """

  @behaviour Plug

  alias Plug.Conn

  @machine_facing_prefixes ["proxy", "api", "events", "mcp"]

  @impl true
  def init(opts), do: Phoenix.Ecto.CheckRepoStatus.init(opts)

  @impl true
  def call(%Conn{path_info: [prefix | _]} = conn, _opts)
      when prefix in @machine_facing_prefixes do
    conn
  end

  def call(conn, opts), do: Phoenix.Ecto.CheckRepoStatus.call(conn, opts)
end
