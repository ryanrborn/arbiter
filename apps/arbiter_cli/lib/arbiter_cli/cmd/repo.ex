defmodule ArbiterCli.Cmd.Repo do
  @moduledoc """
  `arb repo <verb>` — the repo (vernacular: "warship"/"rig") resource. A repo
  is a named repository checkout that workers operate on.

      arb repo list             registered repos with source + path
      arb repo show <name>      one repo's detail (active workers, worktrees)

  Both read from `GET /api/rigs`. In the default vernacular `repo` reads as
  "warship", so `arb warship list` resolves here.
  """

  alias ArbiterCli.{Client, Cmd, Output}

  def run(argv) do
    case argv do
      ["list" | rest] -> Cmd.Warships.run(rest)
      ["ls" | rest] -> Cmd.Warships.run(rest)
      ["show" | rest] -> show(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("repo requires a subcommand", "verbs: list, show")
      [unknown | _] -> Output.die("unknown repo subcommand: #{unknown}", "verbs: list, show")
    end
  end

  defp show(argv) do
    if Output.help?(argv), do: IO.puts(@moduledoc), else: do_show(argv)
  end

  defp do_show(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    name =
      case rest do
        [name] -> name
        [] -> Output.die("repo show requires a repo name: `arb repo show <name>`")
        _ -> Output.die("repo show takes exactly one argument: the repo name")
      end

    case Client.get("/api/rigs") do
      {:ok, %{"data" => rigs}} -> emit_show(find_rig(rigs, name), name, mode)
      {:ok, _} -> emit_show(nil, name, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp find_rig(rigs, name) when is_list(rigs) do
    Enum.find(rigs, fn rig -> rig["name"] == name end)
  end

  defp emit_show(nil, name, :json),
    do: IO.puts(Jason.encode!(%{"error" => "no repo named #{name}"}))

  defp emit_show(nil, name, :text) do
    Output.die("no repo named #{inspect(name)} (try `arb repo list`)")
  end

  defp emit_show(rig, _name, :json), do: IO.puts(Jason.encode!(rig))

  defp emit_show(rig, _name, :text) do
    v = ArbiterCli.Vernacular.fetch()
    IO.puts("#{ArbiterCli.Vernacular.cap(v, "rig")}:       #{rig["name"]}")
    IO.puts("Source:    #{rig["source"]}")
    IO.puts("Path:      #{rig["path"] || "(unknown)"}")
    IO.puts("Workers:   #{rig["polecats"] || 0}")
    IO.puts("Worktrees: #{rig["worktrees"] || 0}")
  end
end
