defmodule ArbiterCli.Cmd.Install do
  @moduledoc """
  `arb install <target>` — install Arbiter's local artifacts.

      arb install cli       [--json]
                            build and install the CLI escript to ~/.local/bin/arb.
      arb install service   [--system] [--uninstall] [--json]
                            install a systemd unit so the stack starts at boot
                            (ExecStart=arb server start). --uninstall removes it.
  """

  alias ArbiterCli.{Cmd, Output}

  def run(argv) do
    case argv do
      ["cli" | rest] -> Cmd.InstallCli.run(rest)
      ["service" | rest] -> Cmd.InstallService.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("install requires a target", "targets: cli, service")
      [unknown | _] -> Output.die("unknown install target: #{unknown}", "targets: cli, service")
    end
  end
end
