defmodule ArbiterCli.Cmd.Prime do
  @moduledoc """
  `arb prime` — dump everything a fresh Claude Code session needs to play
  the Mayor role.

  Output (in order):

    1. **Active workspace** — name, prefix, tracker config.
    2. **Vernacular** — the workspace's custom labels and aliases (only
       printed if non-empty; otherwise "(default gas-town)" is shown).
    3. **Admiral Inbox** — up to 5 most recent unread messages addressed to
       the Admiral. Omitted entirely when there are none.
    4. **Active polecats** — bead_id, status, current_step, runtime.
    5. **Ready beads** — `Issue.ready/0` view (issues with all deps closed).

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
      vernacular: unwrap(sections.vernacular),
      admiral_inbox: unwrap(sections.admiral_inbox),
      polecats: unwrap(sections.polecats),
      ready: unwrap(sections.ready)
    }
  end

  defp unwrap({:ok, val}), do: val
  defp unwrap({:error, msg}), do: %{"error" => msg}

  # ---- gather ------------------------------------------------------------

  defp gather do
    workspace = gather_workspace()
    vernacular = gather_vernacular()

    %{
      workspace: workspace,
      vernacular: vernacular,
      admiral_inbox: gather_admiral_inbox(),
      polecats: gather_polecats(),
      ready: gather_ready(workspace)
    }
  end

  # Up to 5 most recent unread messages addressed to the Admiral. The REST
  # index already sorts newest-first, so a take/2 gives "most recent".
  defp gather_admiral_inbox do
    case Client.get("/api/messages", to_ref: "admiral", unread: "true") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_workspace do
    case Workspace.resolve() do
      {:ok, ws} -> {:ok, ws}
      {:error, msg} -> {:error, msg}
    end
  end

  defp gather_vernacular do
    case Client.get("/api/settings") do
      {:ok, %{"data" => %{"vernacular" => v}}} -> {:ok, v}
      {:ok, _} -> {:ok, %{}}
      {:error, %Client.Error{} = err} -> {:error, err.message}
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
    {worker, issue, workspace} =
      case sections.vernacular do
        {:ok, v} ->
          {Map.get(v, "worker", "polecat"), Map.get(v, "issue", "bead"),
           Map.get(v, "workspace", "workspace")}

        _ ->
          {"polecat", "bead", "workspace"}
      end

    emit_workspace_section(sections.workspace, workspace)
    IO.puts("")
    emit_vernacular_section(sections.vernacular)
    IO.puts("")
    maybe_emit_admiral_inbox(sections.admiral_inbox)
    emit_polecats_section(sections.polecats, worker)
    IO.puts("")
    emit_ready_section(sections.ready, issue)
  end

  # Omitted entirely when there's no unread Admiral mail (or the lookup
  # failed) — a clean briefing shows nothing rather than "(none)" noise.
  defp maybe_emit_admiral_inbox({:ok, []}), do: :ok

  defp maybe_emit_admiral_inbox({:ok, list}) do
    IO.puts("== Admiral Inbox (#{length(list)} unread) ==")

    list
    |> Enum.take(5)
    |> Enum.each(fn m -> IO.puts("  " <> inbox_line(m)) end)

    IO.puts("")
  end

  defp maybe_emit_admiral_inbox(_), do: :ok

  # `[bd-9bn4n9] failure    — Acolyte exited with code 1 (5m ago)`
  defp inbox_line(m) do
    directive = m["directive_ref"] || "-"
    kind = m["kind"] |> to_string() |> String.pad_trailing(10)
    gist = m["subject"] || m["body"] || ""
    gist = gist |> to_string() |> String.split("\n") |> List.first() |> truncate(60)
    "[#{directive}] #{kind} — #{gist}#{age_suffix(m["inserted_at"])}"
  end

  defp age_suffix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> " (#{humanize(DateTime.diff(DateTime.utc_now(), dt, :second))})"
      _ -> ""
    end
  end

  defp age_suffix(_), do: ""

  defp humanize(s) when s < 60, do: "#{max(s, 0)}s ago"
  defp humanize(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp humanize(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp humanize(s), do: "#{div(s, 86_400)}d ago"

  defp emit_workspace_section({:ok, ws}, workspace) do
    IO.puts("== Active #{workspace} ==")
    IO.puts("  name:    #{ws["name"]}")
    IO.puts("  prefix:  #{ws["prefix"]}")
    IO.puts("  id:      #{ws["id"]}")

    tracker_type = get_in(ws, ["config", "tracker", "type"]) || "none"
    IO.puts("  tracker: #{tracker_type}")
  end

  defp emit_workspace_section({:error, msg}, workspace) do
    IO.puts("== Active #{workspace} ==")
    IO.puts("  (could not resolve: #{msg})")
  end

  defp emit_vernacular_section({:ok, vernacular}) do
    IO.puts("== Vernacular ==")

    if vernacular == %{} do
      IO.puts("  (defaults)")
    else
      vernacular
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {k, v} -> IO.puts("  #{k}: #{format_vernacular_value(v)}") end)
    end
  end

  defp emit_vernacular_section({:error, _}), do: IO.puts("== Vernacular ==\n  (n/a)")

  defp format_vernacular_value(v) when is_map(v), do: inspect(v)
  defp format_vernacular_value(v), do: to_string(v)

  defp emit_polecats_section({:ok, []}, worker) do
    IO.puts("== Active #{worker}s ==")
    IO.puts("  (none)")
  end

  defp emit_polecats_section({:ok, list}, worker) do
    IO.puts("== Active #{worker}s (#{length(list)}) ==")

    Enum.each(list, fn p ->
      IO.puts(
        "  #{p["bead_id"]}  status=#{p["status"]}  step=#{p["current_step"]}  rig=#{p["rig"]}"
      )
    end)
  end

  defp emit_polecats_section({:error, msg}, worker) do
    IO.puts("== Active #{worker}s ==")
    IO.puts("  (error: #{msg})")
  end

  defp emit_ready_section({:ok, []}, issue) do
    IO.puts("== Ready #{issue}s ==")
    IO.puts("  (none)")
  end

  defp emit_ready_section({:ok, list}, issue) do
    IO.puts("== Ready #{issue}s (#{length(list)}) ==")

    Enum.each(list, fn i ->
      IO.puts("  #{i["id"]}  P#{i["priority"]}  #{i["issue_type"]}  #{truncate(i["title"], 80)}")
    end)
  end

  defp emit_ready_section({:error, msg}, issue) do
    IO.puts("== Ready #{issue}s ==")
    IO.puts("  (error: #{msg})")
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end
end
