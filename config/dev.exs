import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Repo → git-repo path mapping consumed by `Arbiter.Worker.Dispatch` when it
# provisions a worktree for a freshly-dispatched worker. Beads dispatched with
# a repo string not in this map skip worktree provisioning entirely.
# Repos can also be configured per-workspace via the dashboard
# (Workspace → config["repo_paths"]) so you don't have to redeploy to add one.
config :arbiter, :repo_paths, %{}
config :arbiter, :worktree_root, Path.expand("~/dev/arbiter-worktrees")

# Root for durable, append-only per-run acolyte transcripts
# (Arbiter.Worker.OutputLog). One file per run: <root>/<run_id>.log.
config :arbiter, :output_log_root, Path.expand("~/dev/arbiter-worker-logs")

config :arbiter, Arbiter.Repo,
  database: Path.expand("~/dev/arbiter_dev.sqlite3"),
  journal_mode: :wal,
  busy_timeout: 5000,
  stacktrace: true,
  pool_size: 5

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4848],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "XvJKppBs7YSPbCLNRLar7xEeyzz6ucrVo3IkbSUtfmsyD5JpzUqpoGB5UjIgW2c2",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:arbiter_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:arbiter_web, ~w(--watch)]}
  ]

config :arbiter_web, ArbiterWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/arbiter_web/router\.ex$"E,
      ~r"lib/arbiter_web/(controllers|live|components)/.*\.(ex|heex)$"E
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
