defmodule ArbiterCli.Cmd.InstallCli do
  @moduledoc """
  `arb install-cli [--json]` — rebuild and install the CLI escript.

  Builds the CLI from `apps/arbiter_cli` and installs it to `~/.local/bin/arb`,
  making it executable. Useful when CLI code changes locally and you want the
  updated escript on your PATH without waiting for a full deploy.

  What it does:

    1. **Locate the checkout** — same root resolution as `arb start`/`arb restart`.
    2. **Build the escript** via `mix escript.build` from `apps/arbiter_cli`.
    3. **Install to `~/.local/bin/arb`** and make it executable.

  ## Exit codes

    * `0` — escript built and installed successfully.
    * `1` — build or install failed, or project root could not be located.
  """

  alias ArbiterCli.{Cmd.Start, Output}

  @switches [json: :boolean]

  def run(argv) do
    if "--help" in argv or "-h" in argv do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      root =
        case Start.project_root() do
          {:ok, dir} ->
            dir

          :error ->
            Output.die(
              "could not locate the Arbiter project root (no compose.yml found)",
              "Set ARB_HOME to your Arbiter checkout, or run `arb install-cli` from inside it."
            )
        end

      case build_and_install_cli(root) do
        :ok ->
          emit_success(mode, root)

        {:error, msg} ->
          Output.die("install-cli failed", msg)
      end
    end
  end

  defp build_and_install_cli(root) do
    cli_dir = Path.join(root, "apps/arbiter_cli")

    Start.log_text("Building CLI escript (mix escript.build)…")

    case Start.run_cmd("mix", ["escript.build"], cd: cli_dir, stderr_to_stdout: true) do
      {_out, 0} ->
        escript_path = Path.join(cli_dir, "arb")
        install_path = Path.join(System.user_home!(), ".local/bin/arb")

        # Ensure ~/.local/bin exists
        install_dir = Path.dirname(install_path)

        case File.mkdir_p(install_dir) do
          :ok ->
            # Copy the escript to ~/.local/bin/arb
            case File.copy(escript_path, install_path) do
              {:ok, _} ->
                # Make it executable
                case File.chmod(install_path, 0o755) do
                  :ok ->
                    Start.log_text("Installed CLI escript to #{install_path}")
                    :ok

                  {:error, reason} ->
                    {:error, "Could not make escript executable: #{inspect(reason)}"}
                end

              {:error, reason} ->
                {:error, "Could not copy escript to #{install_path}: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Could not create directory #{install_dir}: #{inspect(reason)}"}
        end

      {out, code} ->
        {:error, "Build failed (exit #{code}): #{String.trim_trailing(out)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Could not run mix: #{inspect(e.original)}"}
  end

  defp emit_success(:json, _root) do
    install_path = Path.join(System.user_home!(), ".local/bin/arb")

    IO.puts(
      Jason.encode!(%{
        status: "ok",
        message: "CLI escript built and installed",
        install_path: install_path
      })
    )
  end

  defp emit_success(:text, _root) do
    install_path = Path.join(System.user_home!(), ".local/bin/arb")

    IO.puts("")
    IO.puts("CLI escript built and installed at #{install_path}")
    IO.puts("Run `arb help` to verify the new version is on your PATH.")
  end
end
