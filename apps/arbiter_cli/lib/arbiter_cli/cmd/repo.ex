defmodule ArbiterCli.Cmd.Repo do
  @moduledoc """
  `arb repo <verb>` — the repo resource. A repo is a named repository
  checkout that workers operate on.

      arb repo list             registered repos with source + path
      arb repo show <name>      one repo's detail (active workers, worktrees)

  Both read from `GET /api/repos`.
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
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    name =
      case rest do
        [name] -> name
        [] -> Output.die("repo show requires a repo name: `arb repo show <name>`")
        _ -> Output.die("repo show takes exactly one argument: the repo name")
      end

    case Client.get("/api/repos") do
      {:ok, %{"data" => repos}} -> emit_show(find_repo(repos, name), name, mode)
      {:ok, _} -> emit_show(nil, name, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp find_repo(repos, name) when is_list(repos) do
    Enum.find(repos, fn repo -> repo["name"] == name end)
  end

  defp emit_show(nil, name, :json),
    do: IO.puts(Jason.encode!(%{"error" => "no repo named #{name}"}))

  defp emit_show(nil, name, :text) do
    Output.die("no repo named #{inspect(name)} (try `arb repo list`)")
  end

  defp emit_show(repo, _name, :json), do: IO.puts(Jason.encode!(repo))

  defp emit_show(repo, _name, :text) do
    IO.puts("Repo:       #{repo["name"]}")
    IO.puts("Source:    #{repo["source"]}")
    IO.puts("Path:      #{repo["path"] || "(unknown)"}")
    IO.puts("Workers:   #{repo["workers"] || 0}")
    IO.puts("Worktrees: #{repo["worktrees"] || 0}")
  end
end
