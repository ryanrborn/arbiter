defmodule ArbiterCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbiter_cli,
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
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # Point at the umbrella-root PLT rather than this app's own build dir, so
  # `mix dialyzer` from inside apps/arbiter_cli reuses the single PLT the root builds
  # instead of spending minutes constructing a near-identical third copy.
  # See the root mix.exs `dialyzer/0` for the rationale in full.
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
      {:req, "~> 0.7.3"},
      {:jason, "~> 1.4"},
      # Static analysis / security scanning. Also declared at the umbrella
      # root, which owns the shared PLT config — see the root mix.exs and the
      # `mix audit` alias there.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      # Test-only: Req.Test stubs run a Plug under the hood.
      {:plug, "~> 1.15", only: :test},
      # Test-only: lets ArbiterCli.ConfigSchemaTest assert its hardcoded enum
      # lists match the real validator (Arbiter.Tasks.Workspace.Changes.
      # ValidateConfig and friends) so the CLI's config reference can't drift
      # out of sync with the server-side source of truth. Never shipped in
      # the escript build (only: :test).
      {:arbiter, in_umbrella: true, only: :test}
    ]
  end
end
