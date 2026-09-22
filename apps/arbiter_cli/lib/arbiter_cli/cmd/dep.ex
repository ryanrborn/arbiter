defmodule ArbiterCli.Cmd.Dep do
  @moduledoc """
  Dependency subcommand router:

      arb dep add  <from> <type> <to>
      arb dep rm   <from> <to> [--type T]
      arb dep list [<issue>] [--type T] [--workspace W] [--json]

  `list` with no `<issue>` lists every edge in the active workspace (see
  `arb where` / `ARB_WORKSPACE` / `--workspace`); with an `<issue>` it lists
  that issue's edges in both directions (bd-1defgu). Each row shows both
  endpoints' id, title, status and priority, so a live edge is
  distinguishable from a closed↔closed one without a second lookup.

  A `conflicts_with` edge (or any other symmetric type) is stored once,
  directed, like every other edge — `list` does not synthesize a mirrored
  second row for it: it appears exactly once in a workspace-wide listing,
  and exactly once when scoped to either one of its two endpoints.

  Edge types:

      depends_on       <from> waits until <to> is closed. Gates dispatch.
      blocks           the mirror image: <to> waits until <from> is closed.
      conflicts_with   symmetric mutex — never run the two at the same time.
                       Enforced by the board scheduler (Autopilot), in either
                       edge direction. A card held by it says
                       `blocked — conflicts with bd-1c4pg3 (running)`, and
                       dispatches once the counterpart merges, closes or is
                       parked.
      parent_of        <from> is the parent (epic) of <to>. Rolls up child
                       progress; does not gate.
      relates_to       informational cross-reference; does not gate.
      discovered_from  <from> was found while working <to>; does not gate.

  A `depends_on` / `blocks` edge that would close a cycle is refused, with the
  cycle named.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["add", from, type, to | _] -> add(from, type, to, mode)
        ["add" | _] -> Output.die("dep add requires: <from> <type> <to>")
        ["rm" | rest] -> rm(rest, mode)
        ["remove" | rest] -> rm(rest, mode)
        ["list" | rest] -> list(rest, mode)
        [] -> Output.die("dep requires a subcommand: `add`, `rm` or `list`")
        [unknown | _] -> Output.die("unknown dep subcommand: #{unknown}")
      end
    end
  end

  defp add(from, type, to, mode) do
    body = %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}

    case Client.post("/api/dependencies", body) do
      {:ok, dep} -> Output.emit_dependency(dep, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp rm(args, mode) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [type: :string, json: :boolean])

    case positional do
      [from, to] ->
        params = if opts[:type], do: [type: opts[:type]], else: []

        case Client.delete("/api/dependencies/" <> from <> "/" <> to, params) do
          {:ok, _} ->
            if mode == :json do
              IO.puts(Jason.encode!(%{ok: true}))
            else
              IO.puts("removed dependency edge: #{from} -> #{to}")
            end

          {:error, err} ->
            Output.die(err)
        end

      _ ->
        Output.die("dep rm requires: <from> <to> [--type T]")
    end
  end

  defp list(args, mode) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [type: :string, workspace: :string, json: :boolean])

    if opts[:workspace], do: System.put_env("ARB_WORKSPACE", opts[:workspace])

    case positional do
      [] -> list_workspace(opts, mode)
      [issue] -> list_issue(issue, opts, mode)
      _ -> Output.die("dep list takes at most one argument: an issue id")
    end
  end

  defp list_workspace(opts, mode) do
    case Workspace.resolve() do
      {:ok, %{"id" => ws_id}} ->
        params = [workspace_id: ws_id] |> put_type(opts[:type])
        fetch_and_emit("/api/dependencies", params, mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp list_issue(issue, opts, mode) do
    params = put_type([], opts[:type])
    fetch_and_emit("/api/dependencies/" <> issue, params, mode)
  end

  defp put_type(params, nil), do: params
  defp put_type(params, type), do: Keyword.put(params, :type, type)

  defp fetch_and_emit(path, params, mode) do
    case Client.get(path, params) do
      {:ok, %{"data" => deps}} -> Output.emit_dependency_list(deps, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
