defmodule Arbiter.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbiter,
      version:
        case System.get_env("RELEASE_VERSION") do
          v when is_binary(v) and byte_size(v) > 0 ->
            v |> String.trim() |> String.trim_leading("v")

          _ ->
            case System.cmd("git", ["describe", "--tags", "--abbrev=0"], stderr_to_stdout: true) do
              {tag, 0} -> tag |> String.trim() |> String.trim_leading("v")
              _ -> "0.0.0"
            end
        end,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Arbiter.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_phoenix, "~> 2.0"},
      {:ash_paper_trail, "~> 0.5"},
      {:ash_sqlite, "~> 0.2"},
      {:ash, "~> 3.0"},

      # Encrypt sensitive Workspace attributes (tracker/merger secrets) at rest.
      # ash_cloak wires the Cloak vault into the Ash resource; cloak provides the
      # AES-256-GCM cipher. See Arbiter.Vault and Arbiter.Tasks.Workspace.
      {:ash_cloak, "~> 0.2.1"},
      {:cloak, "~> 1.1"},
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.2"},

      # Signed, expiring scope tokens for the Arbiter.MCP server (bd-dem49g).
      # Same primitive Phoenix.Token wraps; depended on directly so the domain
      # app mints/verifies tokens without reaching into the web layer.
      {:plug_crypto, "~> 2.0"},

      # Periodic / cron-style scheduling (replaces gt's daemon convoy patrol etc.)
      {:quantum, "~> 3.5"},

      # HTTP client (used by Tracker.Jira, Tracker.GitHub adapters in later tasks)
      {:req, "~> 0.5"},

      # GenStateMachine — workflow driver FSM (gte-015 WorkflowMachine)
      {:gen_state_machine, "~> 3.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run #{__DIR__}/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"]
    ]
  end
end
