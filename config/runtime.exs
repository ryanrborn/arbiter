import Config

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4848"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :arbiter, Arbiter.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  config :arbiter_web, ArbiterWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :arbiter, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
