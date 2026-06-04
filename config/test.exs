import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :arbiter, Arbiter.Repo,
  username: "arbiter",
  password: "arbiter_dev_password",
  hostname: "127.0.0.1",
  port: 5433,
  database: "arbiter_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tP+Fx7+LODDAMtW348NLPMEFQgFBNOCXEW1X3LdQHm5YMSdusJH7vaCC+c18IJgi",
  server: false

config :arbiter, :github_http_stub, true
config :arbiter, :jira_http_stub, true
config :arbiter, :shortcut_http_stub, true
config :arbiter, :gitlab_http_stub, true
config :arbiter, :auto_start_refineries, false

# Acolyte CLAUDE_CONFIG_DIR isolation (bd-3y2mda) is off by default in the suite
# so unit tests never touch the real cache dir or symlink the operator's config.
# Tests that exercise isolation enable it and point :acolyte_config_dir at a tmp
# dir of their own.
config :arbiter, :acolyte_isolate_config, false

# Durable per-run transcript root, isolated under tmp so the suite never
# writes into a real data dir. Tests that assert on transcripts override this
# per-test with a unique tmp dir.
config :arbiter, :output_log_root, Path.join(System.tmp_dir!(), "arbiter-polecat-logs-test")
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true
