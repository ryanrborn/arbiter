defmodule ArbiterReleaseEnv.MixProject do
  use Mix.Project

  # The one place `Arbiter.Worker.ReleaseEnv` lives (bd-2oelme).
  #
  # It is its own umbrella app rather than a module inside `:arbiter` because
  # both `:arbiter` (the server) and `:arbiter_cli` (the `arb` escript) must
  # apply the same release-env scrub before spawning `mix`/`elixir`/`claude`,
  # and `:arbiter_cli` cannot depend on `:arbiter` at runtime — it only pulls it
  # in `only: :test` (see apps/arbiter_cli/mix.exs) because the escript would
  # otherwise have to bundle the whole server tree.
  #
  # Deliberately dependency-free: it uses nothing but `System.get_env/0,1`, so
  # adding it to the escript costs one beam file.

  def project do
    [
      app: :arbiter_release_env,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  # Share the umbrella-root PLT — see the root mix.exs `dialyzer/0`.
  defp dialyzer do
    [
      plt_core_path: "../../priv/plts",
      plt_local_path: "../../priv/plts",
      plt_add_apps: [:mix, :eex, :ex_unit],
      ignore_warnings: "../../.dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :unknown]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Static analysis only. No runtime deps, by design (see @moduledoc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
