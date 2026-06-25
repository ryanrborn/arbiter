import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Repo → git-repo path mapping consumed by `Arbiter.Worker.Dispatch` when it
# provisions a worktree for a freshly-dispatched worker. Tasks dispatched with
# a repo string not in this map skip worktree provisioning entirely.
# Repos can also be configured per-workspace via the dashboard
# (Workspace → config["repo_paths"]) so you don't have to redeploy to add one.
config :arbiter, :repo_paths, %{}
config :arbiter, :worktree_root, Path.expand("~/dev/arbiter-worktrees")

# Root for durable, append-only per-run acolyte transcripts
# (Arbiter.Worker.OutputLog). One file per run: <root>/<run_id>.log.
config :arbiter, :output_log_root, Path.expand("~/dev/arbiter-worker-logs")

# DB path is set in runtime.exs via DATABASE_PATH (all envs). Stacktrace is
# dev-only; the rest of the Repo config is covered by the runtime block.
config :arbiter, Arbiter.Repo, stacktrace: true

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
