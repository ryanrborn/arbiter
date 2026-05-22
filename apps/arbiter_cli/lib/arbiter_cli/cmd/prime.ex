defmodule ArbiterCli.Cmd.Prime do
  @moduledoc """
  `arb prime` — dump everything a fresh Claude Code session needs to play
  the Mayor role.

  Output (in order):

    1. **Active workspace** — name, prefix, tracker config.
    2. **Vernacular** — the workspace's custom labels and aliases (only
       printed if non-empty; otherwise "(default gas-town)" is shown).
    3. **Active polecats** — bead_id, status, current_step, runtime.
    4. **Ready beads** — `Issue.ready/0` view (issues with all deps closed).

  ## What's intentionally NOT in v1

    * Refinery merge-queue items (no server-side endpoint yet).
    * Recent audit-log entries (no server-side endpoint yet).
    * Active convoy state (no list endpoint yet).

  Those need REST endpoints landed before they can be surfaced here. v1
  covers the highest-value subset: what's running, what's actionable,
  and what vocabulary the session should use.

  ## Flags

    * `--json` — emit a single machine-readable JSON blob instead of the
      labelled text sections.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    mode = Output.mode(argv)
    sections = gather()

    case mode do
      :json -> IO.puts(Jason.encode!(to_json(sections)))
      :text -> emit_text(sections)
    end
  end

  defp to_json(sections) do
    %{
      workspace: unwrap(sections.workspace),
      polecats: unwrap(sections.polecats),
      ready: unwrap(sections.ready)
    }
  end

  defp unwrap({:ok, val}), do: val
  defp unwrap({:error, msg}), do: %{"error" => msg}

  # ---- gather ------------------------------------------------------------

  defp gather do
    workspace = gather_workspace()

    %{
      workspace: workspace,
      polecats: gather_polecats(),
      ready: gather_ready(workspace)
    }
  end

  defp gather_workspace do
    case Workspace.resolve() do
      {:ok, ws} -> {:ok, ws}
      {:error, msg} -> {:error, msg}
    end
  end

  defp gather_polecats do
    case Client.get("/api/polecats") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  # Scope ready beads to the active workspace when we know it, so prime
  # doesn't drown the user in imported-from-other-workspaces noise.
  defp gather_ready({:ok, %{"id" => ws_id}}) do
    do_gather_ready(workspace_id: ws_id)
  end

  defp gather_ready(_), do: do_gather_ready([])

  defp do_gather_ready(params) do
    case Client.get("/api/issues/ready", params) do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  # ---- render ------------------------------------------------------------

  defp emit_text(sections) do
    emit_workspace_section(sections.workspace)
    IO.puts("")
    emit_vernacular_section(sections.workspace)
    IO.puts("")
    emit_polecats_section(sections.polecats)
    IO.puts("")
    emit_ready_section(sections.ready)
  end

  defp emit_workspace_section({:ok, ws}) do
    IO.puts("== Active workspace ==")
    IO.puts("  name:    #{ws["name"]}")
    IO.puts("  prefix:  #{ws["prefix"]}")
    IO.puts("  id:      #{ws["id"]}")

    tracker_type = get_in(ws, ["config", "tracker", "type"]) || "none"
    IO.puts("  tracker: #{tracker_type}")
  end

  defp emit_workspace_section({:error, msg}) do
    IO.puts("== Active workspace ==")
    IO.puts("  (could not resolve: #{msg})")
  end

  defp emit_vernacular_section({:ok, ws}) do
    vernacular = get_in(ws, ["config", "vernacular"]) || %{}

    IO.puts("== Vernacular ==")

    if vernacular == %{} do
      IO.puts("  (default gas-town — coordinator=mayor, worker=polecat, etc.)")
    else
      Enum.each(vernacular, fn {k, v} -> IO.puts("  #{k}: #{format_vernacular_value(v)}") end)
    end
  end

  defp emit_vernacular_section({:error, _}), do: IO.puts("== Vernacular ==\n  (n/a)")

  defp format_vernacular_value(v) when is_map(v), do: inspect(v)
  defp format_vernacular_value(v), do: to_string(v)

  defp emit_polecats_section({:ok, []}) do
    IO.puts("== Active polecats ==")
    IO.puts("  (none)")
  end

  defp emit_polecats_section({:ok, list}) do
    IO.puts("== Active polecats (#{length(list)}) ==")

    Enum.each(list, fn p ->
      IO.puts(
        "  #{p["bead_id"]}  status=#{p["status"]}  step=#{p["current_step"]}  rig=#{p["rig"]}"
      )
    end)
  end

  defp emit_polecats_section({:error, msg}) do
    IO.puts("== Active polecats ==")
    IO.puts("  (error: #{msg})")
  end

  defp emit_ready_section({:ok, []}) do
    IO.puts("== Ready beads ==")
    IO.puts("  (none)")
  end

  defp emit_ready_section({:ok, list}) do
    IO.puts("== Ready beads (#{length(list)}) ==")

    Enum.each(list, fn issue ->
      IO.puts(
        "  #{issue["id"]}  P#{issue["priority"]}  #{issue["issue_type"]}  #{truncate(issue["title"], 80)}"
      )
    end)
  end

  defp emit_ready_section({:error, msg}) do
    IO.puts("== Ready beads ==")
    IO.puts("  (error: #{msg})")
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end
end
