defmodule GtElixirWeb.Router do
  use GtElixirWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtElixirWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GtElixirWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/workspace/:id/settings/vernacular", WorkspaceVernacularLive
  end

  scope "/api", GtElixirWeb.Api do
    pipe_through :api

    # Issues
    get "/issues/ready", IssueController, :ready
    get "/issues", IssueController, :index
    post "/issues", IssueController, :create
    get "/issues/:id", IssueController, :show
    patch "/issues/:id", IssueController, :update
    put "/issues/:id", IssueController, :update
    post "/issues/:id/close", IssueController, :close
    post "/issues/:id/reopen", IssueController, :reopen

    # Dependencies
    post "/dependencies", DependencyController, :create
    delete "/dependencies/:from/:to", DependencyController, :delete

    # Convoys
    post "/convoys", ConvoyController, :create
    get "/convoys/:id", ConvoyController, :show
    post "/convoys/:id/close", ConvoyController, :close

    # Workspaces
    get "/workspaces", WorkspaceController, :index
    post "/workspaces", WorkspaceController, :create
    get "/workspaces/:id", WorkspaceController, :show

    # Polecats (workflow runner)
    post "/polecats/sling", PolecatController, :sling
    get "/polecats", PolecatController, :index
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:gt_elixir_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: GtElixirWeb.Telemetry
    end
  end
end
