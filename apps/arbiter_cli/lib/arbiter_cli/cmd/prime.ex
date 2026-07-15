defmodule ArbiterCli.Cmd.Prime do
  @moduledoc """
  `arb prime` — dump everything a fresh Claude Code session needs to play
  the coordinator role.

  Output (in order):

    1. **Global Coordinator Inbox** — up to 5 most recent unread messages
       addressed to the coordinator, not scoped to any single workspace.
       Omitted entirely when there are none.
    2. **Per-workspace blocks** (one per configured workspace, in server order):
       a. Workspace header — name, prefix, id, tracker, security posture.
       b. Standing Orders — the domain's operating disciplines, sourced from
          `config.standing_orders`. Omitted when empty.
       c. Active workers — task_id, status, current_step, runtime, scoped to
          this workspace.
       d. Ready tasks — `Issue.ready/0` view, scoped to this workspace.
       e. Coordinator Inbox — unread messages for this workspace's coordinator.
          Omitted when empty.

  ## Standing Orders are data, not code

  The orders live in per-domain workspace config (`config.standing_orders`),
  not hardcoded here — arbiter is a shared tool, so one fleet's doctrine must
  not leak into every install. Each domain carries its own orders; setting or
  clearing them is a config change, no rebuild required. Each entry is either a
  short imperative string or a `{"title", "detail"}` object.

  ## What's intentionally NOT in v1

    * MergeQueue merge-queue items (no server-side endpoint yet).
    * Recent audit-log entries (no server-side endpoint yet).
    * Open epic / parent-task progress (no dedicated endpoint yet).

  ## `--json` shape

  Emits a JSON object with two keys:

      {
        "coordinator_inbox": [...],
        "workspaces": [
          {
            "workspace": {...},
            "standing_orders": [...],
            "workers": [...],
            "ready": [...],
            "coordinator_inbox": [...]
          }
        ]
      }

  ## Flags

    * `--json` — emit a single machine-readable JSON blob instead of the
      labelled text sections.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      sections = gather()

      case mode do
        :json -> IO.puts(Jason.encode!(to_json(sections)))
        :text -> emit_text(sections)
      end
    end
  end

  defp to_json(sections) do
    %{
      coordinator_inbox: unwrap(sections.global_coordinator_inbox),
      workspaces: Enum.map(sections.workspaces, &workspace_to_json/1)
    }
  end

  defp workspace_to_json(%{} = ws_section) do
    %{
      workspace: ws_section.workspace,
      standing_orders: unwrap(ws_section.standing_orders),
      workers: unwrap(ws_section.workers),
      ready: unwrap(ws_section.ready),
      coordinator_inbox: unwrap(ws_section.coordinator_inbox)
    }
  end

  defp workspace_to_json({:error, msg}), do: %{"error" => msg}

  defp unwrap({:ok, val}), do: val
  defp unwrap({:error, msg}), do: %{"error" => msg}

  # ---- gather ------------------------------------------------------------

  defp gather do
    workspaces_result = gather_workspaces()

    workspace_sections =
      case workspaces_result do
        {:ok, list} -> Enum.map(list, &gather_workspace_section/1)
        {:error, _} = err -> [err]
      end

    %{
      global_coordinator_inbox: gather_global_coordinator_inbox(),
      workspaces: workspace_sections
    }
  end

  defp gather_workspaces do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_workspace_section(ws) do
    ws_id = ws["id"]

    %{
      workspace: ws,
      standing_orders: gather_standing_orders(ws),
      workers: gather_workers(ws_id),
      ready: gather_ready(ws_id),
      coordinator_inbox: gather_coordinator_inbox(ws_id)
    }
  end

  # Standing Orders are per-domain operating disciplines carried in workspace
  # config (`config.standing_orders`). Already embedded in the workspace map,
  # so there's no extra API round-trip.
  defp gather_standing_orders(%{"config" => %{"standing_orders" => orders}})
       when is_list(orders),
       do: {:ok, orders}

  defp gather_standing_orders(_), do: {:ok, []}

  # Up to 5 most recent unread messages addressed to the coordinator. The REST
  # index already sorts newest-first, so a take/2 gives "most recent".
  defp gather_global_coordinator_inbox do
    case Client.get("/api/messages", to_ref: "coordinator", unread: "true") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_workers(ws_id) do
    case Client.get("/api/workers", workspace_id: ws_id) do
      {:ok, %{"data" => list}} -> {:ok, Enum.filter(list, &(&1["workspace_id"] == ws_id))}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_ready(ws_id) do
    case Client.get("/api/issues/ready", workspace_id: ws_id) do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_coordinator_inbox(ws_id) do
    case Client.get("/api/messages", to_ref: "coordinator", workspace_id: ws_id, unread: "true") do
      {:ok, %{"data" => list}} -> {:ok, Enum.filter(list, &(&1["workspace_id"] == ws_id))}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  # ---- render ------------------------------------------------------------

  defp emit_text(sections) do
    maybe_emit_global_coordinator_inbox(sections.global_coordinator_inbox)
    Enum.each(sections.workspaces, &emit_workspace_block/1)
  end

  defp emit_workspace_block(%{} = ws_section) do
    ws = ws_section.workspace
    IO.puts("== Workspace: #{ws["name"]} (#{ws["prefix"]}) ==")
    IO.puts("  name:    #{ws["name"]}")
    IO.puts("  prefix:  #{ws["prefix"]}")
    IO.puts("  id:      #{ws["id"]}")

    tracker_type = get_in(ws, ["config", "tracker", "type"]) || "none"
    IO.puts("  tracker: #{tracker_type}")

    emit_security_posture(ws["security_posture"])
    IO.puts("")

    maybe_emit_standing_orders_section(ws_section.standing_orders)
    emit_workers_section(ws_section.workers, "worker")
    IO.puts("")
    emit_ready_section(ws_section.ready, "issue")
    IO.puts("")
    maybe_emit_coordinator_inbox(ws_section.coordinator_inbox)
  end

  defp emit_workspace_block({:error, msg}) do
    IO.puts("== Workspaces ==")
    IO.puts("  (could not load: #{msg})")
    IO.puts("")
  end

  # Omitted entirely when the domain carries no orders.
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

  # Omitted entirely when there's no unread coordinator mail.
  defp maybe_emit_global_coordinator_inbox({:ok, []}), do: :ok

  defp maybe_emit_global_coordinator_inbox({:ok, list}) do
    IO.puts("== Global Coordinator Inbox (#{length(list)} unread) ==")

    list
    |> Enum.take(5)
    |> Enum.each(fn m -> IO.puts("  " <> inbox_line(m)) end)

    IO.puts("")
  end

  defp maybe_emit_global_coordinator_inbox(_), do: :ok

  # Omitted entirely when there's no unread coordinator mail.
  defp maybe_emit_coordinator_inbox({:ok, []}), do: :ok

  defp maybe_emit_coordinator_inbox({:ok, list}) do
    IO.puts("== Coordinator Inbox (#{length(list)} unread) ==")

    list
    |> Enum.take(5)
    |> Enum.each(fn m -> IO.puts("  " <> inbox_line(m)) end)

    IO.puts("")
  end

  defp maybe_emit_coordinator_inbox(_), do: :ok

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

  # The resolved worker security posture (server-computed; see
  # ArbiterWeb.Api.WorkspaceJSON). Surfaced so a fresh coordinator session sees,
  # up front, what a worker spawned in this domain may and may not do.
  defp emit_security_posture(%{} = posture) do
    sandbox = posture["sandbox"] || %{}
    deny = List.wrap(posture["deny"])
    safe = List.wrap(posture["safe_defaults"])
    allow = List.wrap(posture["allow"])

    net = if Map.get(sandbox, "network", true), do: "on", else: "tools-off"

    IO.puts("  security:")
    IO.puts("    mode:    #{posture["mode"] || "auto"}")

    IO.puts(
      "    sandbox: fs=#{Map.get(sandbox, "filesystem", "worktree")} net=#{net}" <>
        " enabled=#{Map.get(sandbox, "enabled", true)}"
    )

    IO.puts(
      "    deny:    #{length(safe)} safe-default + #{length(deny)} custom" <>
        ", allow: #{length(allow)}"
    )
  end

  defp emit_security_posture(_), do: :ok

  defp emit_workers_section({:ok, []}, worker) do
    IO.puts("== Active #{worker}s ==")
    IO.puts("  (none)")
  end

  defp emit_workers_section({:ok, list}, worker) do
    IO.puts("== Active #{worker}s (#{length(list)}) ==")

    Enum.each(list, fn p ->
      # Claude-driven workers have a frozen workflow step; show their live
      # stream-derived activity instead. See bd-c919xj.
      step =
        if p["claude_session"],
          do: "activity=#{activity_label(p)}",
          else: "step=#{p["current_step"]}"

      IO.puts("  #{p["task_id"]}  status=#{p["status"]}  #{step}  repo=#{p["repo"]}")
    end)
  end

  defp emit_workers_section({:error, msg}, worker) do
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
