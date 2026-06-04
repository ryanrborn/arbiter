defmodule ArbiterCli.Cmd.Prime do
  @moduledoc """
  `arb prime` — dump everything a fresh Claude Code session needs to play
  the Admiral role.

  Output (in order):

    1. **Active workspace** — name, prefix, tracker config.
    2. **Standing Orders** — the active domain's operating disciplines as a
       checklist, sourced from `config.standing_orders`. Surfaced high so the
       disciplines greet a fresh agent before the work list. Omitted entirely
       when the domain carries no orders.
    3. **Vernacular** — the workspace's custom labels and aliases (only
       printed if non-empty; otherwise "(default gas-town)" is shown).
    4. **Admiral Inbox** — up to 5 most recent unread messages addressed to
       the Admiral. Omitted entirely when there are none.
    5. **Active polecats** — bead_id, status, current_step, runtime.
    6. **Ready beads** — `Issue.ready/0` view (issues with all deps closed).

  ## Standing Orders are data, not code

  The orders live in per-domain workspace config (`config.standing_orders`),
  not hardcoded here — arbiter is a shared tool, so one fleet's doctrine must
  not leak into every install. Each domain carries its own orders; setting or
  clearing them is a config change, no rebuild required. Each entry is either a
  short imperative string or a `{"title", "detail"}` object.

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
      standing_orders: unwrap(sections.standing_orders),
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
      standing_orders: gather_standing_orders(workspace),
      vernacular: vernacular,
      admiral_inbox: gather_admiral_inbox(),
      polecats: gather_polecats(),
      ready: gather_ready(workspace)
    }
  end

  # Standing Orders are per-domain operating disciplines carried in workspace
  # config (`config.standing_orders`). We already have the resolved workspace,
  # so there's no extra API round-trip. Absent/empty/unresolved all collapse to
  # `[]` so the section is cleanly omitted on installs without orders.
  defp gather_standing_orders({:ok, %{"config" => %{"standing_orders" => orders}}})
       when is_list(orders),
       do: {:ok, orders}

  defp gather_standing_orders(_), do: {:ok, []}

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
    maybe_emit_standing_orders_section(sections.standing_orders)
    emit_vernacular_section(sections.vernacular)
    IO.puts("")
    maybe_emit_admiral_inbox(sections.admiral_inbox)
    emit_polecats_section(sections.polecats, worker)
    IO.puts("")
    emit_ready_section(sections.ready, issue)
  end

  # Omitted entirely when the domain carries no orders — installs without
  # doctrine see no noise (same contract as the Admiral Inbox section). When
  # present, the orders greet the agent high in the briefing as a checklist.
  defp maybe_emit_standing_orders_section({:ok, []}), do: :ok

  defp maybe_emit_standing_orders_section({:ok, orders}) do
    IO.puts("== Standing Orders ==")
    Enum.each(orders, fn o -> IO.puts("  " <> standing_order_line(o)) end)
    IO.puts("")
  end

  defp maybe_emit_standing_orders_section(_), do: :ok

  # An order is either a short imperative string or a {title, detail} object.
  defp standing_order_line(%{"title" => title} = order) do
    case order["detail"] do
      detail when is_binary(detail) and detail != "" -> "[ ] #{title} — #{detail}"
      _ -> "[ ] #{title}"
    end
  end

  defp standing_order_line(order) when is_binary(order), do: "[ ] #{order}"
  defp standing_order_line(order), do: "[ ] #{inspect(order)}"

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
      # Claude-driven workers have a frozen workflow step; show their live
      # stream-derived activity instead. See bd-c919xj.
      step =
        if p["claude_session"],
          do: "activity=#{activity_label(p)}",
          else: "step=#{p["current_step"]}"

      IO.puts("  #{p["bead_id"]}  status=#{p["status"]}  #{step}  rig=#{p["rig"]}")
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

  # Activity is exposed by the JSON API as a map (%{"label", ...}) or null;
  # render its label, falling back to "working" until the first event lands.
  defp activity_label(p) do
    case p["activity"] do
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> "working"
    end
  end
end
