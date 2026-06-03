defmodule ArbiterWeb.Router do
  use ArbiterWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ArbiterWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:load_branding)
  end

  # Load installation-wide branding into the process dict for the dead render
  # (root layout favicon/title/accent + the `Layouts.app` top-bar wordmark).
  # Live re-renders are covered by the `:branding` on_mount hook.
  defp load_branding(conn, _opts) do
    Arbiter.Branding.put_global()
    conn
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", ArbiterWeb do
    pipe_through(:browser)

    get("/about", PageController, :home)

    live_session :default,
      on_mount: [
        {ArbiterWeb.LiveHooks, :vernacular},
        {ArbiterWeb.LiveHooks, :branding},
        {ArbiterWeb.LiveHooks, :current_path}
      ] do
      live("/", DashboardLive)
      live("/settings/vernacular", GlobalVernacularLive)
      live("/settings/branding", GlobalBrandingLive)
      live("/workspace/:id/settings/vernacular", WorkspaceVernacularLive)
      live("/audit", AuditLogLive)
      live("/polecats/history/:id", RunDetailLive)
      live("/polecats/:bead_id", PolecatDetailLive)
      live("/beads/:id", BeadDetailLive)
    end
  end

  scope "/api", ArbiterWeb.Api do
    pipe_through(:api)

    # Issues
    get("/issues/ready", IssueController, :ready)
    get("/issues", IssueController, :index)
    post("/issues", IssueController, :create)
    get("/issues/:id", IssueController, :show)
    patch("/issues/:id", IssueController, :update)
    put("/issues/:id", IssueController, :update)
    post("/issues/:id/close", IssueController, :close)
    post("/issues/:id/reopen", IssueController, :reopen)

    # Dependencies
    post("/dependencies", DependencyController, :create)
    delete("/dependencies/:from/:to", DependencyController, :delete)

    # Convoys
    post("/convoys", ConvoyController, :create)
    get("/convoys/:id", ConvoyController, :show)
    post("/convoys/:id/close", ConvoyController, :close)

    # Workspaces
    get("/workspaces", WorkspaceController, :index)
    post("/workspaces", WorkspaceController, :create)
    get("/workspaces/:id", WorkspaceController, :show)
    patch("/workspaces/:id", WorkspaceController, :update)
    put("/workspaces/:id", WorkspaceController, :update)

    # Tracker bridge (assignment-as-claim for GitHub Issues)
    post("/workspaces/:workspace_id/claim", ClaimController, :claim)
    get("/workspaces/:workspace_id/sync/plan", ClaimController, :plan)
    post("/workspaces/:workspace_id/sync", ClaimController, :sync)
    get("/workspaces/:workspace_id/tracker/issues", TrackerController, :issues)

    # Global settings
    get("/settings", SettingsController, :show)
    put("/settings/vernacular", SettingsController, :update_vernacular)
    put("/settings/branding", SettingsController, :update_branding)

    # Messages (inter-agent queue: notifications + mailboxes)
    get("/messages", MessageController, :index)
    post("/messages", MessageController, :create)
    post("/messages/:id/read", MessageController, :read)
    delete("/messages", MessageController, :clear)

    # Usage ledger (per-session tokens / cost / duration; rollups)
    get("/usage", UsageController, :summarize)
    get("/usage/events", UsageController, :events)

    # Polecats (workflow runner)
    post("/polecats/sling", PolecatController, :sling)
    get("/polecats/history", RunController, :index)
    get("/polecats/history/:id", RunController, :show)
    get("/polecats", PolecatController, :index)
    get("/polecats/:bead_id", PolecatController, :show)
    get("/polecats/:bead_id/log", PolecatController, :log)
    post("/polecats/:bead_id/stop", PolecatController, :stop)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:arbiter_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: ArbiterWeb.Telemetry)
    end
  end
end
