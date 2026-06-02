import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Rig → git-repo path mapping consumed by `Arbiter.Polecat.Sling` when it
# provisions a worktree for a freshly-slung polecat. Beads slung with a rig
# string not in this map skip worktree provisioning entirely.
# Rigs can also be configured per-workspace via the dashboard
# (Workspace → config["rig_paths"]) so you don't have to redeploy to add one.
config :arbiter, :rig_paths, %{}
config :arbiter, :worktree_root, Path.expand("~/dev/arbiter-worktrees")

# Root for durable, append-only per-run acolyte transcripts
# (Arbiter.Polecat.OutputLog). One file per run: <root>/<run_id>.log.
config :arbiter, :output_log_root, Path.expand("~/dev/arbiter-polecat-logs")

config :arbiter, Arbiter.Repo,
  username: "arbiter",
  password: "arbiter_dev_password",
  hostname: "127.0.0.1",
  port: 5433,
  database: "arbiter_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

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
