import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Repo → git-repo path mapping consumed by `Arbiter.Worker.Dispatch` when it
# provisions a worktree for a freshly-dispatched worker. Tasks dispatched with
# a repo string not in this map skip worktree provisioning entirely.
# Repos can also be configured per-workspace via the dashboard
# (Workspace → config["repo_paths"]) so you don't have to redeploy to add one.
config :arbiter, :repo_paths, %{}
config :arbiter, :worktree_root, Path.expand("~/dev/arbiter-worktrees")

# Root for durable, append-only per-run worker transcripts
# (Arbiter.Worker.OutputLog). One file per run: <root>/<run_id>.log.
config :arbiter, :output_log_root, Path.expand("~/dev/arbiter-worker-logs")

# DB path is set in runtime.exs via DATABASE_PATH (all envs). Stacktrace is
# dev-only; the rest of the Repo config is covered by the runtime block.
config :arbiter, Arbiter.Repo, stacktrace: true

# The dashboard's auth model is "a loopback peer is trusted; there is no
# login" (see ArbiterWeb.Loopback) — bind loopback-only by default (bd-1c4pg3).
# ARB_BIND_ADDRESS overrides it explicitly; ArbiterWeb.Application logs a
# WARNING at boot if the result isn't loopback.
bind_ip =
  case System.get_env("ARB_BIND_ADDRESS") do
    addr when addr in [nil, ""] ->
      {127, 0, 0, 1}

    addr ->
      case :inet.parse_address(String.to_charlist(addr)) do
        {:ok, parsed} -> parsed
        {:error, _} -> raise "ARB_BIND_ADDRESS is not a valid IP address: #{inspect(addr)}"
      end
  end

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [ip: bind_ip, port: String.to_integer(System.get_env("PORT") || "4848")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:arbiter_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:arbiter_web, ~w(--watch)]}
  ]

config :arbiter_web, ArbiterWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/arbiter_web/router\.ex$",
      ~r"lib/arbiter_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :arbiter_web, dev_routes: true
config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :phoenix, :stacktrace_depth, 20
