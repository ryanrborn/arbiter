defmodule Arbiter.Umbrella.MixProject do
  use Mix.Project

  @version (case System.get_env("RELEASE_VERSION") do
              v when is_binary(v) and byte_size(v) > 0 ->
                v |> String.trim() |> String.trim_leading("v")

              _ ->
                case System.cmd("git", ["describe", "--tags", "--abbrev=0"],
                       stderr_to_stdout: true
                     ) do
                  {tag, 0} -> tag |> String.trim() |> String.trim_leading("v")
                  _ -> "0.0.0"
                end
            end)

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # ONE PLT for the whole umbrella.
  #
  # dialyxir defaults `plt_core_path`/`plt_local_path` to the *current*
  # project's build directory. In an umbrella that means `mix dialyzer` run
  # from apps/arbiter, apps/arbiter_web and apps/arbiter_cli would each build
  # and maintain a separate copy of the same multi-minute PLT — three PLTs
  # covering an almost identical dependency tree, none of them reused. Pinning
  # both paths to a single umbrella-root directory (each child app points at
  # `../../priv/plts`) makes the first build pay the cost once and every
  # subsequent run — from the root or from any child app — reuse it.
  #
  # The canonical invocation is `mix dialyzer` from the umbrella root:
  # dialyxir walks every child app's ebin, so one run covers all three.
  def dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      # :mix and :eex are build/runtime-optional apps that lib/mix/tasks and
      # arbiter_cli's escript templates reference; without them dialyzer
      # reports unknown_function for every Mix.* and EEx.* call.
      plt_add_apps: [:mix, :eex, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs",
      # Fail the run if an ignore entry stops matching, so stale suppressions
      # get deleted instead of silently masking a future warning.
      list_unused_filters: true,
      flags: [:error_handling, :unknown]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp releases do
    [
      arbiter: [
        applications: [arbiter: :permanent, arbiter_web: :permanent],
        include_executables_for: [:unix],
        version: @version
      ]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},

      # Static analysis / security scanning — see `mix audit` below and
      # .github/workflows/ci.yml. Declared here (as well as in each child app)
      # so `mix credo`, `mix dialyzer` and `mix sobelow` resolve when run from
      # the umbrella root, which is the only place the umbrella-wide dialyzer
      # PLT config lives.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # Static analysis + security scan. Mirrors the `mix audit` alias the
      # sibling codebases (tonic, vstim) run. Ordered cheapest-first so a
      # formatting slip fails in seconds rather than after dialyzer's PLT work.
      # `format --check-formatted` (not `format`) deliberately: audit reports,
      # it never rewrites.
      #
      # `hex.audit` is deliberately NOT in this list. It currently exits 1 on
      # five pre-existing advisories in the Ash tree (ash_phoenix
      # EEF-CVE-2026-82724/82726/82725/82727, ash_cloak EEF-CVE-2026-81322,
      # ash_sqlite EEF-CVE-2026-77846). Clearing those means upgrading Ash,
      # which is its own piece of work — wiring it in here would make this
      # alias, and therefore CI, red on arrival for reasons unrelated to
      # static analysis. Run `mix hex.audit` by hand until that upgrade lands,
      # then add it back to this list.
      audit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        # Sobelow refuses to scan an umbrella root ("each application should
        # be scanned separately"), so it runs once per app against that app's
        # own .sobelow-conf. `cmd` shells out rather than invoking the Mix
        # task three times, because Mix runs a given task once per session and
        # the 2nd and 3rd invocations would silently no-op.
        "cmd mix sobelow --config",
        "dialyzer"
      ]
    ]
  end
end
