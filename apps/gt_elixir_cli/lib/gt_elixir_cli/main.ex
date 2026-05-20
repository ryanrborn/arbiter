defmodule GtElixirCli.Main do
  @moduledoc """
  Escript entry point. Dispatches the first argument to a subcommand module
  under `GtElixirCli.Cmd.*`.

  Subcommands:

      bd2 show <id>
      bd2 create <title> [--description ...] [--priority ...] [--type ...]
                         [--deps id1,id2] [--labels a,b]
      bd2 close <id> [--reason ...]
      bd2 list [--status ...] [--type ...] [--priority ...] [--labels ...]
      bd2 update <id> [--priority ...] [--append-notes ...]
      bd2 dep add <from> <type> <to>
      bd2 dep rm <from> <to>
      bd2 ready
      bd2 doctor
      bd2 where

  Global flags:
      --json     Emit machine-readable JSON (default is human-readable text)
      -h, --help Show usage

  Env:
      BD2_HOST       Phoenix base URL (default http://127.0.0.1:4000)
      BD2_WORKSPACE  Workspace name to use (default "default")
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
      ["-v"] -> IO.puts("bd2 #{@version}")
      ["--version"] -> IO.puts("bd2 #{@version}")
      [cmd | rest] -> dispatch(cmd, rest)
    end
  end

  defp dispatch(cmd, args) do
    case GtElixirCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args)

      {:unknown, suggestions} ->
        IO.puts(:stderr, "bd2: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `bd2 help` for usage.")
        GtElixirCli.Output.halt(2)
    end
  end

  defp dispatch_known("show", args), do: GtElixirCli.Cmd.Show.run(args)
  defp dispatch_known("create", args), do: GtElixirCli.Cmd.Create.run(args)
  defp dispatch_known("close", args), do: GtElixirCli.Cmd.Close.run(args)
  defp dispatch_known("list", args), do: GtElixirCli.Cmd.List.run(args)
  defp dispatch_known("update", args), do: GtElixirCli.Cmd.Update.run(args)
  defp dispatch_known("dep", args), do: GtElixirCli.Cmd.Dep.run(args)
  defp dispatch_known("ready", args), do: GtElixirCli.Cmd.Ready.run(args)
  defp dispatch_known("doctor", args), do: GtElixirCli.Cmd.Doctor.run(args)
  defp dispatch_known("where", args), do: GtElixirCli.Cmd.Where.run(args)
  defp dispatch_known("sling", args), do: GtElixirCli.Cmd.Sling.run(args)
  defp dispatch_known("help", _args), do: usage_and_exit(0)

  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    GtElixirCli.Output.halt(code)
  end
end
