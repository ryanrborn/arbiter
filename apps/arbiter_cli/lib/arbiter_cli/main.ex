defmodule ArbiterCli.Main do
  @moduledoc """
  Escript entry point. Dispatches the first argument to a subcommand module
  under `ArbiterCli.Cmd.*`.

  Subcommands:

      arb show <id>
      arb create <title> [--description ...] [--priority ...] [--type ...]
                         [--deps id1,id2] [--labels a,b]
      arb close <id> [--reason ...]
      arb list [--status ...] [--type ...] [--priority ...] [--labels ...]
      arb update <id> [--priority ...] [--append-notes ...]
      arb dep add <from> <type> <to>
      arb dep rm <from> <to>
      arb ready
      arb doctor
      arb where
      arb prime
      arb sling <bead-id>
      arb polecat show <bead-id>
      arb polecat stop <bead-id>
      arb inbox [--all | read <id> | clear | <bead-id>]
      arb notify [--limit N]
      arb message <bead-id> <text>
      arb msg <recipient> <body> [--subject ...] [--directive bd-x] [--kind ...]

  Global flags:
      --json     Emit machine-readable JSON (default is human-readable text)
      -h, --help Show usage

  Env:
      ARB_HOST       Phoenix base URL (default http://127.0.0.1:4000)
      ARB_WORKSPACE  Workspace name to use (default "default")
  """

  @version "0.1.0"

  def main(argv) do
    # Start :req's transitive applications. The escript bundles them but does
    # not auto-start. Without this, Req.get crashes with :finch not started.
    {:ok, _} = Application.ensure_all_started(:req)

    case argv do
      [] -> usage_and_exit(0)
      ["help"] -> usage_and_exit(0)
      ["-h"] -> usage_and_exit(0)
      ["--help"] -> usage_and_exit(0)
      ["-v"] -> IO.puts("arb #{@version}")
      ["--version"] -> IO.puts("arb #{@version}")
      [cmd | rest] -> dispatch(cmd, rest)
    end
  end

  defp dispatch(cmd, args) do
    case ArbiterCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args)

      {:unknown, suggestions} ->
        IO.puts(:stderr, "arb: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `arb help` for usage.")
        ArbiterCli.Output.halt(2)
    end
  end

  defp dispatch_known("show", args), do: ArbiterCli.Cmd.Show.run(args)
  defp dispatch_known("create", args), do: ArbiterCli.Cmd.Create.run(args)
  defp dispatch_known("close", args), do: ArbiterCli.Cmd.Close.run(args)
  defp dispatch_known("list", args), do: ArbiterCli.Cmd.List.run(args)
  defp dispatch_known("update", args), do: ArbiterCli.Cmd.Update.run(args)
  defp dispatch_known("dep", args), do: ArbiterCli.Cmd.Dep.run(args)
  defp dispatch_known("ready", args), do: ArbiterCli.Cmd.Ready.run(args)
  defp dispatch_known("doctor", args), do: ArbiterCli.Cmd.Doctor.run(args)
  defp dispatch_known("where", args), do: ArbiterCli.Cmd.Where.run(args)
  defp dispatch_known("sling", args), do: ArbiterCli.Cmd.Sling.run(args)
  defp dispatch_known("prime", args), do: ArbiterCli.Cmd.Prime.run(args)
  defp dispatch_known("polecat", args), do: ArbiterCli.Cmd.Polecat.run(args)
  defp dispatch_known("inbox", args), do: ArbiterCli.Cmd.Inbox.run(args)
  defp dispatch_known("notify", args), do: ArbiterCli.Cmd.Notify.run(args)
  defp dispatch_known("message", args), do: ArbiterCli.Cmd.Message.run(args)
  defp dispatch_known("msg", args), do: ArbiterCli.Cmd.Msg.run(args)
  defp dispatch_known("help", _args), do: usage_and_exit(0)

  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    ArbiterCli.Output.halt(code)
  end
end
