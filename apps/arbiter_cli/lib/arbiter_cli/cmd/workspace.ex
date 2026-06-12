defmodule ArbiterCli.Cmd.Workspace do
  @moduledoc """
  `arb workspace <verb>` — inspect the configured workspaces.

      arb workspace list        all workspaces (name, prefix, tracker)
      arb workspace show <id>   one workspace's detail incl. config

  Reads from `GET /api/workspaces` and `GET /api/workspaces/:id`.
  """

  alias ArbiterCli.{Client, Output, Vernacular}

  def run(argv) do
    case argv do
      ["list" | rest] ->
        list(rest)

      ["ls" | rest] ->
        list(rest)

      ["show" | rest] ->
        show(rest)

      ["--help" | _] ->
        IO.puts(@moduledoc)

      ["-h" | _] ->
        IO.puts(@moduledoc)

      [] ->
        Output.die("workspace requires a subcommand", "verbs: list, show")

      [unknown | _] ->
        Output.die("unknown workspace subcommand: #{unknown}", "verbs: list, show")
    end
  end

  defp list(argv) do
    mode = Output.mode(argv)

    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    id =
      case rest do
        [id] -> id
        [] -> Output.die("workspace show requires a workspace id or name")
        _ -> Output.die("workspace show takes exactly one argument: the workspace id")
      end

    case Client.get("/api/workspaces/" <> id) do
      {:ok, ws} -> Output.emit_workspace(ws, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text) do
    v = Vernacular.fetch()
    IO.puts("(no #{Vernacular.label(v, "workspace")}s)")
  end

  defp emit_list(list, :text) do
    v = Vernacular.fetch()
    IO.puts("#{Vernacular.cap(v, "workspace")}s (#{length(list)}):")

    Enum.each(list, fn ws ->
      IO.puts("  #{ws["name"]}  prefix=#{ws["prefix"]}  id=#{ws["id"]}")
    end)
  end
end
