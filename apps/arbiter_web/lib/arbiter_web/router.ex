defmodule ArbiterWeb.Router do
  use ArbiterWeb, :router

  # Content-Security-Policy for the dashboard (sobelow Config.CSP).
  #
  # The board renders content Arbiter did not author — worker transcripts,
  # PR and review bodies, tracker issue text. HEEx escapes it, but a CSP is
  # the layer that still holds if something ever renders raw: it stops an
  # injected tag from loading or phoning home to an origin that is not ours.
  #
  # Directive by directive, and why each is what it is:
  #
  #   * `script-src 'self'` with no `'unsafe-inline'`. The generator's inline
  #     theme <script> was moved to assets/js/theme.js precisely so this could
  #     stay strict — an inline allowance here would give back most of what
  #     the policy is for.
  #   * `style-src` keeps `'unsafe-inline'`: LiveView's JS commands
  #     (`JS.show/1`, `JS.transition/1`) work by writing inline `style`
  #     attributes, and daisyUI theme variables are set the same way. Without
  #     it every transition in the UI silently stops.
  #   * `fonts.googleapis.com` / `fonts.gstatic.com`: assets/css/app.css
  #     `@import`s Geist from Google Fonts and the browser fetches the woff2
  #     from gstatic. Drop both entries the day those get self-hosted.
  #   * `connect-src` names `ws:`/`wss:` explicitly rather than relying on
  #     `'self'` covering the LiveView socket — browsers disagree about that,
  #     and getting it wrong takes the whole dashboard offline.
  #   * `frame-ancestors 'none'` (clickjacking), `object-src 'none'`,
  #     `base-uri 'self'` (stops an injected <base> re-pointing every
  #     relative URL), `form-action 'self'`.
  @csp "default-src 'self'; " <>
         "script-src 'self'; " <>
         "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " <>
         "font-src 'self' data: https://fonts.gstatic.com; " <>
         "img-src 'self' data: blob:; " <>
         "connect-src 'self' ws: wss:; " <>
         "frame-ancestors 'none'; " <>
         "base-uri 'self'; " <>
         "object-src 'none'; " <>
         "form-action 'self'"

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ArbiterWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @csp})
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(ArbiterWeb.Plugs.ApiAuth)
  end

  scope "/", ArbiterWeb do
    pipe_through(:browser)

    get("/about", PageController, :home)

    live_session :default,
      on_mount: [
        {ArbiterWeb.LiveHooks, :current_path},
        {ArbiterWeb.LiveHooks, :live},
        {ArbiterWeb.LiveHooks, :quota},
        {ArbiterWeb.LiveHooks, :coordinator_inbox}
      ] do
      live("/", BoardLive)
      live("/audit", AuditLogLive)
      live("/usage", UsageLive)
      live("/reviews", ReviewIndexLive)

      # Entity index pages (list everything, filterable + paged) and their
      # detail pages. Literal segments are declared before the dynamic
      # `:task_id`/`:id` catch-alls so e.g. `/workers/history` isn't claimed
      # as a worker detail.
      live("/tasks", TaskIndexLive)
      live("/tasks/new", TaskNewLive)
      live("/tasks/:id", TaskDetailLive)

      live("/merge_queue", MergeQueueIndexLive)

      live("/workspaces", WorkspaceIndexLive)
      live("/workspaces/:id", WorkspaceDetailLive)

      live("/skills", SkillIndexLive)

      # The loop-engineering proposal queue (bd-9j2g3x). Read + decide only —
      # nothing here applies itself.
      live("/loop", LoopProposalIndexLive)

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
    post("/issues/:id/promote", IssueController, :promote)

    # Dependencies
    post("/dependencies", DependencyController, :create)
    delete("/dependencies/:from/:to", DependencyController, :delete)

    # Loop-analysis pass (Stage 1, bd-dyfaq3) — operator-invoked, report-only.
    # Persisting the proposals it implies is a separate POST (Stage 2,
    # bd-9j2g3x), so the GET's zero-writes guarantee is structural.
    get("/loop/analyze", LoopController, :analyze)
    post("/loop/propose", LoopController, :propose)
    post("/loop/propose/repo_doc_patch", LoopController, :propose_repo_doc_patch)

    # The reviewable-proposal queue. No auto-apply: an operator decides.
    get("/loop/pending", LoopController, :pending_index)
    get("/loop/pending/:id", LoopController, :pending_show)
    post("/loop/pending/:id/apply", LoopController, :pending_apply)
    post("/loop/pending/:id/reject", LoopController, :pending_reject)

    # Repos (repo/project checkouts workers operate on)
    get("/repos", RepoController, :index)

    # Skills (system-wide, user-authored worker skill registry)
    get("/skills", SkillController, :index)
    post("/skills", SkillController, :create)
    get("/skills/:id", SkillController, :show)
    patch("/skills/:id", SkillController, :update)
    put("/skills/:id", SkillController, :update)
    delete("/skills/:id", SkillController, :delete)

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

    # Server health (migrations, etc.)
    get("/server/migrations", ServerController, :migrations)

    # Usage ledger (per-session tokens / cost / duration; rollups)
    get("/usage", UsageController, :summarize)
    get("/usage/events", UsageController, :events)

    # External review audit records (bd-31fh9e)
    get("/external_reviews", ExternalReviewController, :index)
    # Durable per-review corpus: prompt + raw transcript + tool uses (bd-7efini)
    get("/external_reviews/:id/transcript", ExternalReviewController, :transcript)

    # Internal ReviewGate structured round outcomes (bd-aqyjuc)
    get("/review_gate_rounds", ReviewGateRoundController, :index)

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
    get("/workers/:task_id/prompt", WorkerController, :prompt)
    get("/workers/:task_id/run_log_list", WorkerController, :run_log_list)
    post("/workers/:task_id/stop", WorkerController, :stop)

    # Graph queue operations (C5 of #482)
    post("/queue/:task_id/resume", QueueController, :resume)
    post("/queue/:task_id/retry_auto_resolve", QueueController, :retry_auto_resolve)
    post("/queue/:task_id/restart_watchdog", QueueController, :restart_watchdog)
    post("/queue/:task_id/rerun_ci", QueueController, :rerun_ci)
    post("/queue/:task_id/mark_ci_external", QueueController, :mark_ci_external)

    # Board scheduler (autopilot) operations
    post("/scheduler/pause", SchedulerController, :pause)
    post("/scheduler/resume", SchedulerController, :resume)
    get("/scheduler/status", SchedulerController, :status)
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
