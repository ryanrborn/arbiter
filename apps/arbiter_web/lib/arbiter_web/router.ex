defmodule ArbiterWeb.Router do
  use ArbiterWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ArbiterWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", ArbiterWeb do
    pipe_through(:browser)

    get("/about", PageController, :home)

    live_session :default,
      on_mount: [
        {ArbiterWeb.LiveHooks, :current_path},
        {ArbiterWeb.LiveHooks, :quota}
      ] do
      live("/", DashboardLive)
      live("/audit", AuditLogLive)
      live("/usage", UsageLive)

      # Entity index pages (list everything, filterable + paged) and their
      # detail pages. Literal segments are declared before the dynamic
      # `:task_id`/`:id` catch-alls so e.g. `/workers/history` isn't claimed
      # as a worker detail.
      live("/tasks", TaskIndexLive)
      live("/tasks/:id", TaskDetailLive)

      live("/merge_queue", MergeQueueIndexLive)

      live("/workers", WorkerIndexLive)
      live("/workers/history", RunIndexLive)
      live("/workers/history/:id", RunDetailLive)
      live("/workers/:task_id", WorkerDetailLive)
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

    # Repos (repo/project checkouts workers operate on)
    get("/repos", RepoController, :index)

    # Workspaces
    get("/workspaces", WorkspaceController, :index)
    post("/workspaces", WorkspaceController, :create)
    get("/workspaces/:id", WorkspaceController, :show)
    patch("/workspaces/:id", WorkspaceController, :update)
    put("/workspaces/:id", WorkspaceController, :update)
    patch("/workspaces/:id/config", WorkspaceController, :patch_config)

    # Tracker bridge (assignment-as-claim for GitHub Issues)
    post("/workspaces/:workspace_id/claim", ClaimController, :claim)
    get("/workspaces/:workspace_id/sync/plan", ClaimController, :plan)
    post("/workspaces/:workspace_id/sync", ClaimController, :sync)
    get("/workspaces/:workspace_id/tracker/issues", TrackerController, :issues)
    post("/workspaces/:workspace_id/tracker/tickets", TrackerController, :create_ticket)

    # Messages (inter-agent queue: notifications + mailboxes)
    get("/messages", MessageController, :index)
    post("/messages", MessageController, :create)
    post("/messages/:id/read", MessageController, :read)
    delete("/messages", MessageController, :clear)

    # MCP token management (mint coordinator tokens, verify any token)
    post("/mcp/tokens", McpController, :mint_token)
    post("/mcp/tokens/verify", McpController, :verify_token)

    # Version stamp
    get("/version", VersionController, :show)

    # Usage ledger (per-session tokens / cost / duration; rollups)
    get("/usage", UsageController, :summarize)
    get("/usage/events", UsageController, :events)

    # Anthropic quota snapshot (captured by the local proxy)
    get("/quota", QuotaController, :show)

    # Workers (workflow runner)
    post("/workers/dispatch", WorkerController, :dispatch)
    post("/workers/review", WorkerController, :review)
    post("/workers/:task_id/resume", WorkerController, :resume)
    get("/workers/history", RunController, :index)
    get("/workers/history/:id", RunController, :show)
    get("/workers", WorkerController, :index)
    get("/workers/:task_id", WorkerController, :show)
    get("/workers/:task_id/log", WorkerController, :log)
    post("/workers/:task_id/stop", WorkerController, :stop)
  end

  # Local transparent proxy to api.anthropic.com (bd-5boun6). Workers route
  # Claude CLI traffic here so the `anthropic-ratelimit-unified-*` quota headers
  # are captured. Not piped through `:api` — the controller forwards the raw
  # body/headers and streams SSE responses itself, owning content negotiation.
  scope "/proxy/anthropic", ArbiterWeb do
    match(:*, "/*path", AnthropicProxyController, :forward)
  end

  # Server-push event stream — long-lived chunked HTTP connection for coordinator
  # sessions. Auth via query-string token; not piped through :api because the
  # response is application/x-ndjson (not JSON) and content negotiation would
  # reject it. The controller owns auth and content-type entirely.
  scope "/", ArbiterWeb.Api do
    get("/events", EventController, :stream)
  end

  # Arbiter.MCP — the in-process Model Context Protocol server for agent
  # sessions. A single JSON-RPC-over-Streamable-HTTP endpoint; capability is the
  # per-spawn scope token in the Authorization header, decoded in the plug. Not
  # piped through `:api` so the plug owns content negotiation and auth itself.
  scope "/mcp" do
    forward("/", ArbiterWeb.MCP.Plug)
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
