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
                  _ -> File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
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
      releases: releases()
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
      {:phoenix_live_view, ">= 0.0.0"}
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
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
