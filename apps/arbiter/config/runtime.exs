import Config

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(System.user_home!(), ".arbiter/arbiter.sqlite3")

  config :arbiter, Arbiter.Repo,
    database: database_path,
    journal_mode: :wal,
    busy_timeout: 5000
end
