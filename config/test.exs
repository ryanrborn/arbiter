import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :gt_elixir, GtElixir.Repo,
  username: "gt_elixir",
  password: "gt_elixir_dev_password",
  hostname: "127.0.0.1",
  port: 5432,
  database: "gt_elixir_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gt_elixir_web, GtElixirWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tP+Fx7+LODDAMtW348NLPMEFQgFBNOCXEW1X3LdQHm5YMSdusJH7vaCC+c18IJgi",
  server: false

# Route GtElixir.GitHub HTTP calls through Req.Test stubs.
config :gt_elixir, :github_http_stub, true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
