import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :arbiter, Arbiter.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "arbiter_test#{System.get_env("MIX_TEST_PARTITION", "")}.sqlite3"
    ),
  journal_mode: :wal,
  busy_timeout: 5000,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tP+Fx7+LODDAMtW348NLPMEFQgFBNOCXEW1X3LdQHm5YMSdusJH7vaCC+c18IJgi",
  server: false

# Cloak vault key for the test suite. Arbiter.Vault reads ARBITER_CLOAK_KEY at
# runtime and refuses to boot without it; this config fallback injects a fixed
# (non-secret) 32-byte AES key so the suite encrypts/decrypts workspace secrets
# without depending on a real environment variable. Never used outside :test.
config :arbiter, Arbiter.Vault, key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

config :arbiter, :github_http_stub, true
config :arbiter, :jira_http_stub, true
config :arbiter, :shortcut_http_stub, true
config :arbiter, :gitlab_http_stub, true
config :arbiter, :oauth_usage_http_stub, true
config :arbiter, :auto_start_refineries, false

# Acolyte CLAUDE_CONFIG_DIR isolation (bd-3y2mda) is off by default in the suite
# so unit tests never touch the real cache dir or symlink the operator's config.
# Tests that exercise isolation enable it and point :acolyte_config_dir at a tmp
# dir of their own.
config :arbiter, :acolyte_isolate_config, false

# Anthropic quota proxy (bd-5boun6): off in test so adapter/dispatch specs see
# the raw spawn env. Specs that exercise the wiring flip this on per-test.
config :arbiter, :anthropic_proxy,
  enabled: false,
  base_url: "http://127.0.0.1:4848/proxy/anthropic"

# Arbiter.MCP (bd-dem49g): the server stays enabled (Plug tests exercise it), but
# per-spawn `.mcp.json` injection into worktrees is off by default so existing
# Sling tests don't write config files or mint tokens. Tests that exercise
# injection flip `inject_config: true` themselves.
#
# `sse_max_lifetime_ms: 0` closes a GET /mcp SSE stream right after the initial
# keepalive flush, so the synchronous test request returns instead of blocking
# on the held-open stream (bd-3m4yop).
config :arbiter, Arbiter.MCP, inject_config: false, sse_max_lifetime_ms: 0

# Durable per-run transcript root, isolated under tmp so the suite never
# writes into a real data dir. Tests that assert on transcripts override this
# per-test with a unique tmp dir.
config :arbiter, :output_log_root, Path.join(System.tmp_dir!(), "arbiter-worker-logs-test")

# Stalled-acolyte detection (bd-awi4nw): shorten the post-exit grace so the
# deferred classify+escalate check fires fast under test. Still > 0 so a normal
# completion's in-flight `arb done` wins the race before the check runs.
config :arbiter, :worker_exit_grace_ms, 50
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true

# Disable the CredentialWarden's periodic probes in test — there's no real agent
# CLI to call, and we test the warden's logic via direct GenServer calls.
config :arbiter, :credential_warden, enabled: false

# Disable the quota refresh probe in test — there's no proxy or real Claude CLI;
# tests that exercise probe logic inject a :probe_fun stub and enable explicitly.
config :arbiter, :quota_refresh_probe, enabled: false
