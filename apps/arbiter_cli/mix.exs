defmodule ArbiterCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbiter_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :eex is bundled so `arb init`'s compiled templates can resolve their
      # `@assign` references at runtime inside the escript (EEx.Engine lives
      # in the :eex app, which isn't pulled in by default).
      extra_applications: [:logger, :inets, :ssl, :eex] ++ extra_applications(Mix.env())
    ]
  end

  defp extra_applications(:test), do: [:plug]
  defp extra_applications(_), do: []

  # Escript build config: produces `arb` binary that runs `ArbiterCli.Main.main/1`.
  defp escript do
    [
      main_module: ArbiterCli.Main,
      name: "arb",
      app: nil
    ]
  end

  defp aliases do
    [setup: ["deps.get", "escript.build"]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Test-only: Req.Test stubs run a Plug under the hood.
      {:plug, "~> 1.15", only: :test}
    ]
  end
end
