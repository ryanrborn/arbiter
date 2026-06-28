import Config

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4848"))]

# Single source of truth for the SQLite DB path. Applies to all environments
# (dev, prod) except test, which sets its own tmp path in config/test.exs.
#
# Default: ~/.arbiter/arbiter.sqlite3 (the canonical post-cutover location).
# Until T7 (DB-copy cutover) completes, set DATABASE_PATH to point at the
# live database so the server never boots against an empty file.
if config_env() != :test do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.expand("~/.arbiter/arbiter.sqlite3")

  config :arbiter, Arbiter.Repo,
    database: database_path,
    journal_mode: :wal,
    busy_timeout: 5000,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
end

if proxy_timeout = System.get_env("ANTHROPIC_PROXY_RECEIVE_TIMEOUT") do
  config :arbiter_web, :anthropic_proxy, receive_timeout: String.to_integer(proxy_timeout)
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  config :arbiter_web, ArbiterWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    server: true,
    url: [
      host: System.get_env("PHX_HOST") || "localhost",
      port: String.to_integer(System.get_env("PORT", "4848")),
      scheme: "http"
    ],
    check_origin: false

  config :arbiter, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
