defmodule Arbiter.MCP.Tools do
  @moduledoc """
  The `Arbiter.MCP` tool handlers — the agent-native route back into the domain.
  Each handler calls Ash directly (the same actions the REST controllers and
  `arb` subcommands take) and returns plain, JSON-friendly maps.

  Phase 1 ships the read tools plus the one narrowed polecat write
  (`bead_update_progress`); Phase 2 adds the coordinator-only mutating tools —
  `bead_create` / `bead_update` / `bead_close` / `bead_reopen`, `dep_add` /
  `dep_remove` (grouping/epics use a `parent_of` edge), the `polecat_*` lifecycle family
  (`polecat_sling` / `polecat_resume` / `polecat_review` / `polecat_stop` /
  `polecat_list`), `message_send`, `notify_list`, the `tracker_*` bridge
  (`tracker_claim` / `tracker_sync`), `workspace_list`, and `usage_summarize`
  (see `docs/mcp-server-design.md` §8). The acolyte-dispatch tools
  (`polecat_sling` / `polecat_resume` / `polecat_review`) carry the
  sling-recursion guardrail (`can_sling` + `depth`, §4.3).

  Handlers take `(scope, arguments)` where `scope` is an `Arbiter.MCP.Scope` and
  `arguments` is the decoded `tools/call` arguments object (string keys). They
  return:

    * `{:ok, map}` — structured result (serialized to `structuredContent`);
    * `{:error, {:unauthorized, msg}}` — a scope violation (the transport maps it
      to a JSON-RPC error, per `docs/mcp-server-design.md` §4.2);
    * `{:error, {:not_found | :invalid, msg}}` — an operational failure (returned
      as an `isError: true` tool result so the agent gets a usable message).

  Tier-level visibility (which tier may call which tool) is enforced upstream in
  `Arbiter.MCP.Catalog`; these handlers enforce the *data-level* rules —
  own-bead and workspace isolation — via `Arbiter.MCP.Scope`.
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Beads.Claim
  alias Arbiter.Beads.Dependency
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Sling
  alias Arbiter.Trackers
  alias Arbiter.Usage

  require Ash.Query

  @progress_fields ~w(notes qa_notes deployment_notes pr_body)

  # ---- bead_show ----------------------------------------------------------

  @doc "Read a single bead. Polecat: its own bead only. Coordinator: any in its workspace."
  @spec bead_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_show(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, args, id) do
      {:ok, serialize_bead(load_progress(issue))}
    end
  end

  # ---- bead_ready ---------------------------------------------------------

  @doc """
  List ready (unblocked, open) beads in a workspace. Coordinator only. The
  workspace is resolved from the optional `workspace` arg, else the scope's bound
  workspace, else the installation default.
  """
  @spec bead_ready(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_ready(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      beads =
        [workspace_id: ws_id]
        |> Issue.ready()
        |> Enum.map(&serialize_bead_summary/1)

      {:ok, %{beads: beads, count: length(beads)}}
    end
  end

  # ---- inbox_check --------------------------------------------------------

  @doc """
  The unread mailbox for a bead, marked read on read (the structured replacement
  for `arb inbox <bead>`). Polecat: its own bead. Coordinator: the `bead_id`
  argument, within its workspace.
  """
  @spec inbox_check(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def inbox_check(%Scope{} = scope, args) do
    with {:ok, to_ref} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, bead} <- fetch_bead(scope, args, to_ref) do
      messages = Message.inbox(to_ref, workspace_id: bead.workspace_id)
      _ = Enum.each(messages, &Message.mark_read/1)

      {:ok,
       %{
         bead_id: to_ref,
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages)
       }}
    end
  end

  # ---- coordinator_inbox --------------------------------------------------

  @doc """
  The unread Admiral escalation mailbox for the bound workspace, marked read on
  return — the structured replacement for `arb message inbox` / `arb inbox`.
  Coordinator only; the polecat tier is denied at the catalog level.

  Lists all unread messages where `to_ref == "admiral"` in the workspace and
  marks each one read, so the dashboard unread count drops to 0. Optional
  `clear: true` also destroys the already-read tail (`Message.clear_read/2`),
  mirroring `arb inbox clear`.
  """
  @spec coordinator_inbox(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox(%Scope{} = scope, args) do
    with {:ok, clear} <- fetch_bool(args, "clear", false),
         {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      messages = Message.inbox("admiral", workspace_id: ws_id)
      _ = Enum.each(messages, &Message.mark_read/1)

      cleared = if clear, do: Message.clear_read("admiral", workspace_id: ws_id), else: 0

      {:ok,
       %{
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages),
         cleared: cleared
       }}
    end
  end

  # ---- workspace_show -----------------------------------------------------

  @doc """
  A workspace: config, vernacular, and the resolved acolyte security posture.
  Resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default. A workspace-bound scope (polecat) can
  only ever inspect its own workspace.
  """
  @spec workspace_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_show(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      case Ash.get(Workspace, ws_id) do
        {:ok, %Workspace{} = ws} -> {:ok, serialize_workspace(ws)}
        _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
      end
    end
  end

  # ---- bead_update_progress ----------------------------------------------

  @doc """
  The polecat's one write: record `notes` / `qa_notes` / `deployment_notes` /
  `pr_body` on its own bead (the structured replacement for `arb issue update
  <id> --qa-notes …`). It cannot flip status, reprioritize, or touch another
  bead. Coordinator: the same narrow write against any bead in its workspace.
  """
  @spec bead_update_progress(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_update_progress(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, args, id),
         {:ok, attrs} <- progress_attrs(args) do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, serialize_bead(updated)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ======================================================================
  # Phase 2 — coordinator-only mutating tools (docs/mcp-server-design.md §8)
  # ======================================================================

  # ---- bead_create --------------------------------------------------------

  @doc """
  Create a bead in a workspace. Coordinator only. The target workspace is
  resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default — and `workspace_id` is then forced
  onto the bead. Backs onto `Ash.create(Issue, …)` (the same path `arb create` /
  the REST `POST /api/issues` take), so a workspace with a tracker configured
  still mirrors the new bead upstream.
  """
  @spec bead_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, title} <- require_string(args, "title"),
         {:ok, attrs} <- collect_attrs(args, bead_create_spec()) do
      attrs = attrs |> Map.put("title", title) |> Map.put("workspace_id", ws_id)

      case Ash.create(Issue, attrs) do
        {:ok, issue} -> {:ok, serialize_bead(issue)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- bead_update --------------------------------------------------------

  @doc """
  Update a bead in the scope's workspace (status / priority / title / …).
  Coordinator only. The `:closed` status is rejected here — closing goes through
  `bead_close`, which runs the close FSM + teardown. Backs onto the bead's
  `:update` action.
  """
  @spec bead_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_update(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, args, id),
         {:ok, attrs} <- collect_attrs(args, bead_update_spec()),
         :ok <- require_some(attrs, "provide at least one field to update") do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, serialize_bead(updated)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- bead_close ---------------------------------------------------------

  @doc """
  Close a bead in the scope's workspace via the `:close` action (sets status,
  runs the polecat/worktree teardown, and optionally syncs the close upstream
  when `close_upstream: true`). Coordinator only.
  """
  @spec bead_close(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_close(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, args, id),
         {:ok, close_upstream} <- fetch_bool(args, "close_upstream", false) do
      attrs =
        %{close_upstream: close_upstream}
        |> maybe_put(:reason, fetch_string(args, "reason"))

      case Ash.update(issue, attrs, action: :close) do
        {:ok, closed} -> {:ok, serialize_bead(closed)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- bead_reopen --------------------------------------------------------

  @doc """
  Reopen a closed bead in the scope's workspace via the `:reopen` action (clears
  `closed_at`, returns it to `:open` and the ready queue, and best-effort
  reopens the linked tracker issue). Coordinator only. Reopening is the only
  supported path out of `:closed` — the `:update` FSM rejects that transition —
  so a non-closed bead is reported as an operational error.
  """
  @spec bead_reopen(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_reopen(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, args, id) do
      case Ash.update(issue, %{}, action: :reopen) do
        {:ok, reopened} -> {:ok, serialize_bead(reopened)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- dep_add ------------------------------------------------------------

  @doc """
  Add a dependency edge between two beads in the scope's workspace. Coordinator
  only. Both endpoints must resolve inside the workspace (a cross-workspace id is
  reported not-found). Backs onto `Ash.create(Dependency, …)`.
  """
  @spec dep_add(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_add(%Scope{} = scope, args) do
    with {:ok, from} <- require_string(args, "from_issue_id"),
         {:ok, to} <- require_string(args, "to_issue_id"),
         {:ok, type} <- require_enum(args, "type", Dependency.types()),
         {:ok, from_bead} <- fetch_bead(scope, args, from),
         {:ok, _to_bead} <- fetch_bead_in_workspace(from_bead.workspace_id, to) do
      attrs =
        %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}
        |> maybe_put("notes", fetch_string(args, "notes"))
        |> maybe_put("created_by", fetch_string(args, "created_by"))

      case Ash.create(Dependency, attrs) do
        {:ok, dep} -> {:ok, serialize_dependency(dep)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- dep_remove ---------------------------------------------------------

  @doc """
  Remove dependency edges between two beads in the scope's workspace. Coordinator
  only. With no `type` every edge between the pair is removed; with a `type`
  only that edge. Idempotent — removing an absent edge reports `removed: 0`.
  """
  @spec dep_remove(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_remove(%Scope{} = scope, args) do
    with {:ok, from} <- require_string(args, "from_issue_id"),
         {:ok, to} <- require_string(args, "to_issue_id"),
         {:ok, type} <- optional_enum(args, "type", Dependency.types()),
         {:ok, from_bead} <- fetch_bead(scope, args, from),
         {:ok, _to_bead} <- fetch_bead_in_workspace(from_bead.workspace_id, to) do
      edges = find_dep_edges(from, to, type)
      _ = Enum.each(edges, &Ash.destroy!/1)
      {:ok, %{from_issue_id: from, to_issue_id: to, removed: length(edges)}}
    end
  end

  # ---- message_send -------------------------------------------------------

  @doc """
  Send a message to a bead's mailbox — the structured replacement for
  `arb message <bead> <text>`. Available to **both** tiers, with the envelope
  set from the scope so the sender identity cannot be spoofed:

    * a **coordinator** sends a `:direction` from `"coordinator"` down to any
      bead in its workspace;
    * a **polecat** raises a `:flag` from its own bound bead to a sibling.

  `workspace_id` is pinned to the recipient bead's own workspace (a polecat to
  its bound workspace), so a message can only ever be created alongside its
  recipient. Backs onto `Messages.send_mail/1`.
  """
  @spec message_send(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def message_send(%Scope{} = scope, args) do
    with {:ok, to_ref} <- require_string(args, "bead_id"),
         {:ok, body} <- require_string(args, "body"),
         {:ok, ws_id} <- message_workspace(scope, args, to_ref) do
      attrs =
        scope
        |> message_envelope(ws_id, to_ref)
        |> Map.put(:body, body)
        |> maybe_put(:subject, fetch_string(args, "subject"))

      case Message.send_mail(attrs) do
        {:ok, message} -> {:ok, serialize_message(message)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # The workspace a message lands in. A polecat is pinned to its bound workspace.
  # A coordinator infers it from the recipient bead itself (entity inference,
  # honoring an explicit `workspace` arg), which also validates the recipient
  # exists and is reachable by the scope.
  defp message_workspace(%Scope{tier: :polecat, workspace_id: ws_id}, _args, _to_ref),
    do: {:ok, ws_id}

  defp message_workspace(%Scope{tier: :coordinator} = scope, args, to_ref) do
    with {:ok, bead} <- fetch_bead(scope, args, to_ref), do: {:ok, bead.workspace_id}
  end

  # The sender identity + kind are derived from the scope, never the client: a
  # coordinator directs (`from: "coordinator"`); a polecat flags from its own
  # bound bead. Both are pinned to the resolved workspace.
  defp message_envelope(%Scope{tier: :coordinator}, ws_id, to_ref) do
    %{
      kind: :direction,
      workspace_id: ws_id,
      from_ref: "coordinator",
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :polecat, bead_id: bead_id}, ws_id, to_ref) do
    %{
      kind: :flag,
      workspace_id: ws_id,
      from_ref: bead_id,
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  # ---- polecat_sling ------------------------------------------------------

  @doc """
  Dispatch a polecat to work a bead in the scope's workspace. **Coordinator only,
  and the strongest-gated tool.** It enforces the sling-recursion guardrail
  (`docs/mcp-server-design.md` §4.3):

    1. The scope must carry `can_sling` — a coordinator minted without it (and
       every polecat, which never carries it) is refused.
    2. The scope's `depth` must be below the configured `Arbiter.MCP.max_depth/0`
       — cheap insurance against a misconfigured coordinator fan-out.

  The slung polecat's own scope token is minted one level deeper (`depth + 1`),
  so a chain of dispatches is tracked. With a `provider` (`"claude"` | `"gemini"`,
  or the deprecated `with_claude: true` alias) a worker session is started;
  without one the bead simply parks `:in_progress` (no agent spawned).
  Backs onto `Arbiter.Polecat.Sling.sling/2`.
  """
  @spec polecat_sling(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_sling(%Scope{} = scope, args) do
    with :ok <- ensure_can_sling(scope),
         :ok <- ensure_sling_depth(scope),
         {:ok, bead_id} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, _bead} <- fetch_bead(scope, args, bead_id) do
      case Sling.sling(bead_id, sling_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_sling(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, sling_error_message(reason)}}
      end
    end
  end

  # ---- polecat_resume -----------------------------------------------------

  @doc """
  Re-attach a fresh acolyte to a bead's **preserved outpost** worktree
  (`arb resume`). Coordinator only, and — like `polecat_sling` — gated by the
  sling-recursion guardrail (`can_sling` + `depth`): resume spawns a worker, so
  the same recursion concerns apply. The child polecat's scope is minted one
  level deeper. Backs onto `Arbiter.Polecat.Sling.resume/2`.
  """
  @spec polecat_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_resume(%Scope{} = scope, args) do
    with :ok <- ensure_can_sling(scope),
         :ok <- ensure_sling_depth(scope),
         {:ok, bead_id} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, _bead} <- fetch_bead(scope, args, bead_id) do
      case Sling.resume(bead_id, dispatch_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_sling(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, sling_error_message(reason)}}
      end
    end
  end

  # ---- polecat_review -----------------------------------------------------

  @doc """
  Dispatch a **review-only** acolyte against the PR/MR linked to a bead
  (`arb review`): no worktree, no per-bead branch, no route through the
  Crucible/merger. Coordinator only, and gated by the sling-recursion guardrail
  (`can_sling` + `depth`) — a review dispatch spawns an agent. The child
  polecat's scope is minted one level deeper. Backs onto
  `Arbiter.Polecat.Sling.sling/2` with `review: true`.
  """
  @spec polecat_review(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_review(%Scope{} = scope, args) do
    with :ok <- ensure_can_sling(scope),
         :ok <- ensure_sling_depth(scope),
         {:ok, bead_id} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, _bead} <- fetch_bead(scope, args, bead_id) do
      opts =
        scope
        |> dispatch_opts(args)
        |> Keyword.put(:review, true)
        |> review_claude_flag(args)

      case Sling.sling(bead_id, opts) do
        {:ok, result} -> {:ok, serialize_sling(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, sling_error_message(reason)}}
      end
    end
  end

  # ---- polecat_stop -------------------------------------------------------

  @doc """
  Stop the polecat currently working a bead (`arb polecat stop`). Coordinator
  only. The bead is resolved through `fetch_bead`, so a coordinator can only
  stop polecats for beads in its own workspace; a bead with no live polecat is
  reported as not-found. Stopping is teardown — it never spawns — so it does not
  require `can_sling`. Backs onto `Arbiter.Polecat.stop/2`.
  """
  @spec polecat_stop(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_stop(%Scope{} = scope, args) do
    with {:ok, bead_id} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, _bead} <- fetch_bead(scope, args, bead_id) do
      case Polecat.stop(bead_id, :normal) do
        :ok -> {:ok, %{bead_id: bead_id, stopped: true}}
        {:error, :not_found} -> {:error, {:not_found, "no running polecat for bead #{bead_id}"}}
      end
    end
  end

  # ---- polecat_list -------------------------------------------------------

  @doc """
  List active polecats in the scope's workspace. Coordinator only. Backs onto
  `Arbiter.Polecat.list_children/0`, filtered to the scope's workspace_id so a
  coordinator never sees polecats running in other workspaces.
  """
  @spec polecat_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      children =
        Arbiter.Polecat.list_children()
        |> Enum.filter(&(&1.workspace_id == ws_id))

      bead_ids = Enum.map(children, & &1.bead_id)
      costs = Arbiter.Polecat.Stats.bead_costs_usd(bead_ids)

      polecats =
        Enum.map(children, &serialize_polecat_summary(&1, Map.get(costs, &1.bead_id, 0.0)))

      {:ok, %{polecats: polecats, count: length(polecats)}}
    end
  end

  # ---- bead_list ----------------------------------------------------------

  @doc """
  List beads in the scope's workspace with optional filters. Coordinator only.
  Accepts optional `status`, `priority`, and `issue_type` filters. Always
  scoped to the coordinator's workspace. Backs onto `Ash.read(Issue, ...)`.
  """
  @spec bead_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, status} <- optional_enum(args, "status", Issue.statuses()),
         {:ok, issue_type} <- optional_enum(args, "issue_type", Issue.issue_types()),
         {:ok, priority} <- optional_integer(args, "priority") do
      query =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws_id)
        |> maybe_filter_status(status)
        |> maybe_filter_issue_type(issue_type)
        |> maybe_filter_priority(priority)

      beads =
        query
        |> Ash.read!()
        |> Enum.map(&serialize_bead_summary/1)

      {:ok, %{beads: beads, count: length(beads)}}
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: Ash.Query.filter(query, status == ^status)

  defp maybe_filter_issue_type(query, nil), do: query

  defp maybe_filter_issue_type(query, issue_type),
    do: Ash.Query.filter(query, issue_type == ^issue_type)

  defp maybe_filter_priority(query, nil), do: query

  defp maybe_filter_priority(query, priority),
    do: Ash.Query.filter(query, priority == ^priority)

  # ---- usage_summarize ----------------------------------------------------

  @doc """
  Roll up the token/cost usage ledger for the scope's workspace. Coordinator
  only. `by` is required (one of `Arbiter.Usage.valid_groupings/0`); `since`
  (ISO-8601) and `limit` are optional. `workspace_id` is forced to the scope's
  workspace. Backs onto `Arbiter.Usage.summarize/1`.
  """
  @spec usage_summarize(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_summarize(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, by} <- require_enum(args, "by", Usage.valid_groupings()),
         {:ok, since} <- optional_datetime(args, "since"),
         {:ok, limit} <- optional_integer(args, "limit") do
      opts =
        [by: by, workspace_id: ws_id]
        |> maybe_put_kw(:since, since)
        |> maybe_put_kw(:limit, limit)

      case Usage.summarize(opts) do
        {:ok, rollups} ->
          {:ok, %{by: Atom.to_string(by), rollups: rollups, count: length(rollups)}}

        {:error, reason} ->
          {:error, {:invalid, "usage_summarize failed: #{inspect(reason)}"}}
      end
    end
  end

  # ---- notify_list --------------------------------------------------------

  @doc """
  The most recent notifications (broadcast events: completions, milestones,
  system events) for the scope's workspace. Available to both tiers and always
  scoped to the bound workspace. Read-only — notifications are never consumed.
  Optional `limit` (default 20). Backs onto `Messages.recent_notifications/2`.
  """
  @spec notify_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def notify_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, limit} <- optional_integer(args, "limit") do
      notifications =
        (limit || 20)
        |> Message.recent_notifications(workspace_id: ws_id)
        |> Enum.map(&serialize_message/1)

      {:ok, %{notifications: notifications, count: length(notifications)}}
    end
  end

  # ---- tracker_claim ------------------------------------------------------

  @doc """
  Claim an external tracker issue into a bead (`arb claim`). Coordinator only.
  Fetches the issue by `ref` via the workspace's tracker, verifies it is
  assigned to the workspace user (the claim signal; skip with `force: true`),
  and creates a linked bead. Idempotent — returns the existing bead if one
  already references the issue. Backs onto `Arbiter.Beads.Claim.claim/3`.
  """
  @spec tracker_claim(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_claim(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, ref} <- require_string(args, "ref"),
         {:ok, force} <- fetch_bool(args, "force", false),
         {:ok, workspace} <- fetch_workspace(ws_id) do
      case Claim.claim(workspace, ref, force: force) do
        {:ok, status, bead} -> {:ok, Map.put(serialize_bead(bead), :claim_status, to_str(status))}
        {:error, reason} -> {:error, {:invalid, claim_error_message(reason)}}
      end
    end
  end

  # ---- tracker_sync -------------------------------------------------------

  @doc """
  Reconcile the workspace's beads against its external tracker (`arb sync`): open
  assigned issues with no bead get a linked bead; open beads whose issue is
  unassigned/closed get closed. Coordinator only. With `dry: true` the plan is
  returned without acting. No-ops cleanly when the tracker does not support
  reconciliation. Backs onto `Arbiter.Beads.Claim.plan/1` + `apply_plan/2`.
  """
  @spec tracker_sync(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_sync(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, dry} <- fetch_bool(args, "dry", false),
         {:ok, workspace} <- fetch_workspace(ws_id),
         {:ok, plan} <- claim_plan(workspace) do
      actions = Enum.map(plan, &serialize_claim_action/1)

      if dry do
        {:ok, %{applied: false, actions: actions, count: length(actions)}}
      else
        {:ok, results} = Claim.apply_plan(workspace, plan)

        {:ok,
         %{
           applied: true,
           actions: actions,
           results: Enum.map(results, &serialize_claim_result/1),
           count: length(actions)
         }}
      end
    end
  end

  # ---- workspace_list -----------------------------------------------------

  @doc """
  List the configured workspaces (id, name, prefix, tracker type). Coordinator
  only. This is a deliberate exception to the per-call workspace isolation every
  other tool enforces: it is a read-only *enumeration* of non-sensitive summary
  fields (no config, no security posture — those stay behind `workspace_show`
  for the bound workspace), the discovery surface the operator/coordinator needs
  to know which workspaces exist. Backs onto `Ash.read(Workspace)`.
  """
  @spec workspace_list(Scope.t(), map()) :: {:ok, map()}
  def workspace_list(%Scope{}, _args) do
    workspaces =
      Workspace
      |> Ash.read!()
      |> Enum.map(&serialize_workspace_summary/1)

    {:ok, %{workspaces: workspaces, count: length(workspaces)}}
  end

  # ---- shared resolution / fetch -----------------------------------------

  # Resolve + authorize the target bead id for this scope from the named arg
  # (default "id"). Polecat: own bead only; coordinator: id required.
  defp resolve_bead_id(scope, args, key \\ "id") do
    case Scope.own_bead(scope, fetch_string(args, key)) do
      {:ok, id} ->
        {:ok, id}

      {:error, :unauthorized} ->
        {:error, {:unauthorized, "this scope may only act on its own bead"}}

      {:error, :missing} ->
        {:error, {:invalid, "`#{key}` is required"}}
    end
  end

  # Fetch a bead and enforce workspace isolation. Honors an optional `workspace`
  # arg (name or id): a workspace-bound scope may only ever reach its own
  # workspace; a workspace-agnostic coordinator either targets the named
  # workspace or, with no arg, infers it from the bead itself (entity inference).
  # A bead outside the resolved workspace is reported not-found so existence does
  # not leak across workspaces.
  defp fetch_bead(scope, args, id) do
    with {:ok, target_ws} <- authorized_workspace(scope, args) do
      case Ash.get(Issue, id) do
        {:ok, %Issue{} = issue} ->
          if workspace_match?(issue.workspace_id, target_ws),
            do: {:ok, issue},
            else: {:error, {:not_found, "bead #{id} not found"}}

        _ ->
          {:error, {:not_found, "bead #{id} not found"}}
      end
    end
  end

  # Fetch a bead and require it to live in `ws_id` exactly — the second-endpoint
  # check for dependency tools, so both endpoints of an edge stay in one
  # workspace even for a workspace-agnostic coordinator inferring from the first.
  defp fetch_bead_in_workspace(ws_id, id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ^ws_id} = issue} -> {:ok, issue}
      _ -> {:error, {:not_found, "bead #{id} not found"}}
    end
  end

  # A `nil` target means "any workspace" (a workspace-agnostic coordinator that
  # named no workspace — the bead's own workspace stands).
  defp workspace_match?(_ws, nil), do: true
  defp workspace_match?(ws, ws), do: true
  defp workspace_match?(_ws, _target), do: false

  # The workspace this call is authorized to operate in, honoring an optional
  # `workspace` arg (name or id). Returns `{:ok, ws_id}` where `ws_id` may be
  # `nil` — meaning the caller is a workspace-agnostic coordinator that named no
  # workspace, so entity inference / the installation default applies downstream.
  #
  # A scope bound to one workspace (every polecat; a legacy workspace-bound
  # coordinator) may only ever resolve to its own workspace — naming a different
  # one is `{:error, {:unauthorized, …}}`.
  defp authorized_workspace(%Scope{} = scope, args) do
    case fetch_string(args, "workspace") do
      nil ->
        {:ok, scope.workspace_id}

      ref ->
        with {:ok, ws} <- resolve_workspace_ref(ref) do
          cond do
            is_nil(scope.workspace_id) -> {:ok, ws.id}
            scope.workspace_id == ws.id -> {:ok, ws.id}
            true -> {:error, {:unauthorized, "this scope is bound to a single workspace"}}
          end
        end
    end
  end

  # A *concrete* workspace id for tools that operate within one workspace
  # (create + enumerate). Resolution order: explicit `workspace` arg → the
  # scope's bound workspace → the installation default workspace.
  defp resolve_workspace_id(%Scope{} = scope, args) do
    with {:ok, ws_id} <- authorized_workspace(scope, args) do
      if is_binary(ws_id), do: {:ok, ws_id}, else: default_workspace_id()
    end
  end

  # Resolve a `workspace` arg (workspace id first, then name) to a Workspace.
  defp resolve_workspace_ref(ref) when is_binary(ref) do
    with :error <- workspace_by_id(ref),
         :error <- workspace_by_name(ref) do
      {:error, {:not_found, "workspace #{inspect(ref)} not found"}}
    end
  end

  defp workspace_by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp workspace_by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The installation default workspace, for a workspace-agnostic coordinator that
  # named none: the lone workspace if there is exactly one, else the one named
  # "default" (the boot-seeded default). Ambiguous otherwise — the caller must
  # pass `workspace` explicitly.
  defp default_workspace_id do
    case Ash.read!(Workspace) do
      [%Workspace{id: id}] ->
        {:ok, id}

      [] ->
        {:error, {:invalid, "no workspaces exist on this installation"}}

      many ->
        case Enum.find(many, &(&1.name == "default")) do
          %Workspace{id: id} ->
            {:ok, id}

          nil ->
            {:error, {:invalid, "multiple workspaces; pass `workspace` (name or id) explicitly"}}
        end
    end
  end

  # Load the child-progress rollup calcs for a bead so the serializer can emit
  # `child_total` / `child_closed`. Best-effort: on any load error the bead is
  # returned unchanged (the serializer then omits the progress fields).
  defp load_progress(%Issue{} = issue) do
    Ash.load!(issue, [:child_total, :child_closed])
  rescue
    _ -> issue
  end

  # Keep only the three allowed progress fields; require at least one.
  defp progress_attrs(args) do
    attrs =
      for field <- @progress_fields, (val = fetch_string(args, field)) != nil, into: %{} do
        {String.to_existing_atom(field), val}
      end

    if map_size(attrs) == 0 do
      {:error, {:invalid, "provide at least one of: #{Enum.join(@progress_fields, ", ")}"}}
    else
      {:ok, attrs}
    end
  end

  # ---- Phase 2 arg coercion + validation ---------------------------------

  # Build a string-keyed attrs map from `args`, taking only the keys in `spec`
  # and coercing each to its declared type. Returns `{:ok, map}` or
  # `{:error, {:invalid, msg}}` on the first bad value. Absent keys are skipped.
  defp collect_attrs(args, spec) when is_map(args) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      case Map.fetch(args, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} ->
          case coerce_field(type, raw) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, why} -> {:halt, {:error, {:invalid, "`#{key}` #{why}"}}}
          end
      end
    end)
  end

  defp collect_attrs(_args, _spec), do: {:ok, %{}}

  defp coerce_field(:string, v) when is_binary(v), do: {:ok, v}
  defp coerce_field(:string, _), do: {:error, "must be a string"}

  defp coerce_field(:integer, v) when is_integer(v), do: {:ok, v}

  defp coerce_field(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_field(:integer, _), do: {:error, "must be an integer"}

  defp coerce_field(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp coerce_field(:boolean, "true"), do: {:ok, true}
  defp coerce_field(:boolean, "false"), do: {:ok, false}
  defp coerce_field(:boolean, _), do: {:error, "must be a boolean"}

  defp coerce_field({:enum, allowed}, v) do
    case to_allowed_atom(v, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "must be one of: #{allowed_list(allowed)}"}
    end
  end

  # A required non-empty string argument.
  defp require_string(args, key) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      s -> {:ok, s}
    end
  end

  # A required enum argument coerced against `allowed`.
  defp require_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # An optional enum argument; `{:ok, nil}` when absent.
  defp optional_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:ok, nil}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  defp enum_or_error(raw, key, allowed) do
    case to_allowed_atom(raw, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "`#{key}` must be one of: #{allowed_list(allowed)}"}}
    end
  end

  defp optional_integer(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      v when is_integer(v) ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:invalid, "`#{key}` must be an integer"}}
        end

      _ ->
        {:error, {:invalid, "`#{key}` must be an integer"}}
    end
  end

  defp optional_datetime(args, key) do
    case fetch_string(args, key) do
      nil ->
        {:ok, nil}

      raw ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:error, {:invalid, "`#{key}` must be an ISO-8601 datetime"}}
        end
    end
  end

  defp fetch_bool(args, key, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid, "`#{key}` must be a boolean"}}
    end
  end

  defp require_some(attrs, msg) do
    if map_size(attrs) == 0, do: {:error, {:invalid, msg}}, else: :ok
  end

  defp to_allowed_atom(v, allowed) when is_binary(v) do
    atom = String.to_existing_atom(v)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp to_allowed_atom(_v, _allowed), do: :error

  defp allowed_list(allowed), do: Enum.map_join(allowed, ", ", &Atom.to_string/1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(kw, _key, nil), do: kw
  defp maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # ---- Phase 2 field specs (arg key → coercion type) ---------------------

  defp bead_create_spec do
    [
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"target_branch", :string}
    ]
  end

  defp bead_update_spec do
    [
      {"title", :string},
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"status", {:enum, Issue.statuses()}},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string}
    ]
  end

  # ---- Phase 2 sling guardrail + opts (docs/mcp-server-design.md §4.3) ----

  defp ensure_can_sling(%Scope{can_sling: true}), do: :ok

  defp ensure_can_sling(%Scope{}),
    do: {:error, {:unauthorized, "this scope may not sling (can_sling is not set)"}}

  defp ensure_sling_depth(%Scope{depth: depth}) do
    max = MCP.max_depth()
    if depth < max, do: :ok, else: {:error, {:unauthorized, "sling depth limit (#{max}) reached"}}
  end

  # The opts common to every acolyte-dispatch tool (sling / resume / review):
  # the optional `rig` / `model` overrides plus the child scope depth, minted
  # one level deeper (`depth + 1`) so a chain of dispatches stays tracked.
  defp dispatch_opts(%Scope{depth: depth}, args) do
    [depth: depth + 1]
    |> maybe_put_kw(:rig, fetch_string(args, "rig"))
    |> maybe_put_kw(:model, fetch_string(args, "model"))
  end

  # Map `polecat_sling` arguments onto `Sling.sling/2` opts, mirroring the REST
  # `POST /api/polecats/sling` contract: a `provider` dispatches a real worker
  # session (forcing that agent via `agent_type`); the deprecated `with_claude`
  # boolean is still honored as an alias for `provider: "claude"`; otherwise the
  # bead parks `:in_progress` (no Driver).
  defp sling_opts(scope, args) do
    base = dispatch_opts(scope, args)

    case sling_provider(args) do
      nil ->
        Keyword.put(base, :start_driver, false)

      type when is_atom(type) ->
        base |> Keyword.put(:start_claude, true) |> Keyword.put(:agent_type, type)
    end
  end

  # Resolve the worker provider from `polecat_sling` args. Prefers the explicit
  # `provider` field (`"claude"` | `"gemini"`), falling back to the deprecated
  # `with_claude: true` alias. Returns `nil` when neither selects a worker — the
  # bead then parks in_progress.
  defp sling_provider(args) do
    case Map.get(args, "provider") do
      "claude" ->
        :claude

      "gemini" ->
        :gemini

      _ ->
        case Map.get(args, "with_claude") do
          v when v in [true, "true"] -> :claude
          _ -> nil
        end
    end
  end

  # `polecat_review` is claude-driven by default (a reviewer with no agent has
  # nothing to do), mirroring `POST /api/polecats/review`. `with_claude: false`
  # dispatches the review without spawning an agent (the test affordance).
  defp review_claude_flag(opts, args) do
    case Map.get(args, "with_claude") do
      v when v in [false, "false"] -> Keyword.put(opts, :start_claude, false)
      _ -> Keyword.put(opts, :start_claude, true)
    end
  end

  defp sling_error_message({:bead_closed, id}),
    do: "bead #{id} is closed; reopen it before slinging"

  defp sling_error_message(:no_rig_configured), do: "no rigs configured for this workspace"
  defp sling_error_message({:rig_not_found, rig}), do: "rig #{inspect(rig)} is not configured"

  defp sling_error_message({:ambiguous_rig, rigs}),
    do: "multiple rigs available (#{Enum.join(rigs, ", ")}); pass `rig` explicitly"

  defp sling_error_message({:bead_awaiting_review, id}),
    do: "bead #{id} is already awaiting review"

  # Resume-specific (`Sling.resume/2`).
  defp sling_error_message(:no_outpost),
    do: "no preserved outpost worktree for this bead — nothing to resume; sling it fresh instead"

  defp sling_error_message(:rig_unknown),
    do: "could not resolve the rig for this bead; pass `rig` explicitly"

  defp sling_error_message({:acolyte_active, status}),
    do: "an acolyte is still active for this bead (#{status}); stop it before resuming"

  defp sling_error_message(other), do: "sling failed: #{inspect(other)}"

  # ---- Phase 2 fetch helpers ---------------------------------------------

  defp find_dep_edges(from, to, nil) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to)
    |> Ash.read!()
  end

  defp find_dep_edges(from, to, type) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to and type == ^type)
    |> Ash.read!()
  end

  # The scope's own workspace, loaded for the tracker bridge tools.
  defp fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
    end
  end

  # Wrap `Claim.plan/1` so an adapter/tracker error surfaces as a tool error
  # rather than crashing the handler.
  defp claim_plan(workspace) do
    case Claim.plan(workspace) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, {:invalid, claim_error_message(reason)}}
    end
  end

  defp claim_error_message(:tracker_not_supported),
    do: "workspace tracker does not support claim/sync (e.g. tracker is `none`)"

  defp claim_error_message({:not_assigned, who}),
    do:
      "issue is not assigned to the workspace user (#{inspect(who)}); pass force=true to override"

  defp claim_error_message({:already_claimed, _body}),
    do:
      "this issue has already been claimed by another Arbiter installation (force=true to override)"

  defp claim_error_message({:invalid_ref, raw}), do: "invalid issue ref: #{inspect(raw)}"

  defp claim_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  end

  defp claim_error_message(other), do: inspect(other)

  defp fetch_string(args, key) when is_map(args) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp fetch_string(_args, _key), do: nil

  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  defp serialize_bead(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      description: i.description,
      acceptance: i.acceptance,
      notes: i.notes,
      qa_notes: i.qa_notes,
      deployment_notes: i.deployment_notes,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type),
      auto_close: i.auto_close,
      assignee: i.assignee,
      tracker_type: to_str(i.tracker_type),
      tracker_ref: i.tracker_ref,
      pr_ref: i.pr_ref,
      pr_body: i.pr_body,
      target_branch: i.target_branch,
      workspace_id: i.workspace_id,
      closed_at: iso(i.closed_at),
      created_at: iso(i.created_at),
      updated_at: iso(i.updated_at)
    }
    |> put_progress(i)
  end

  # Include the child-progress rollup when the calcs are loaded (bead_show loads
  # them). Omitted when not loaded so other serialize paths stay cheap.
  defp put_progress(map, %Issue{child_total: t, child_closed: c})
       when is_integer(t) and is_integer(c) do
    Map.merge(map, %{child_total: t, child_closed: c, child_open: max(t - c, 0)})
  end

  defp put_progress(map, _i), do: map

  defp serialize_bead_summary(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type)
    }
  end

  defp serialize_dependency(%Dependency{} = d) do
    %{
      id: d.id,
      from_issue_id: d.from_issue_id,
      to_issue_id: d.to_issue_id,
      type: to_str(d.type),
      notes: d.notes,
      created_by: d.created_by,
      created_at: iso(d.created_at)
    }
  end

  # The sling result carries live pids/ports; render the JSON-safe subset (pids
  # inspected to strings), mirroring `ArbiterWeb.Api.PolecatJSON.sling/1`. `depth`
  # is the slung polecat's scope depth (parent + 1).
  defp serialize_sling(result, depth) do
    %{
      bead: serialize_bead(result.bead),
      polecat: %{bead_id: result.bead.id, pid: inspect(result.polecat_pid)},
      machine: %{id: result.machine_id, pid: inspect(result.machine_pid)},
      worktree_path: result.worktree_path,
      claude_started: not is_nil(result.claude_port),
      depth: depth
    }
  end

  defp serialize_polecat_summary(snap, cost_usd) do
    meta = Map.get(snap, :meta, %{}) || %{}
    routing = Map.get(meta, :routing_config) || %{}
    model_id = Map.get(meta, :model) || Map.get(routing, :model)

    %{
      bead_id: snap.bead_id,
      status: to_str(snap.status),
      rig: snap.rig,
      started_at: iso(snap.started_at),
      activity: Map.get(meta, :activity),
      provider: Map.get(meta, :provider) || Map.get(routing, :provider),
      model: Arbiter.Polecat.Stats.short_model_name(model_id),
      cost_usd: cost_usd
    }
  end

  defp serialize_message(%Message{} = m) do
    %{
      id: m.id,
      kind: to_str(m.kind),
      from_ref: m.from_ref,
      to_ref: m.to_ref,
      subject: m.subject,
      body: m.body,
      directive_ref: m.directive_ref,
      inserted_at: iso(m.inserted_at)
    }
  end

  defp serialize_workspace(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config || %{},
      security: SecurityPolicy.summary(SecurityPolicy.resolve(ws))
    }
  end

  # The non-sensitive summary `workspace_list` returns — id/name/prefix/tracker
  # only, never config or security posture.
  defp serialize_workspace_summary(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      prefix: ws.prefix,
      tracker_type: to_str(Trackers.workspace_type(ws))
    }
  end

  # The planned reconcile actions / per-action results from the tracker bridge,
  # mirroring `ArbiterWeb.Api.ClaimController`'s shapes.
  defp serialize_claim_action({:create, ref, summary}),
    do: %{action: "create", ref: ref, title: summary[:title], html_url: summary[:html_url]}

  defp serialize_claim_action({:close, bead_id, reason}),
    do: %{action: "close", bead_id: bead_id, reason: reason}

  defp serialize_claim_result({:created, bead}),
    do: %{outcome: "created", bead: serialize_bead_summary(bead)}

  defp serialize_claim_result({:closed, bead}),
    do: %{outcome: "closed", bead: serialize_bead_summary(bead)}

  defp serialize_claim_result({:error, action, reason}),
    do: %{outcome: "error", action: serialize_claim_action(action), reason: inspect(reason)}

  defp to_str(nil), do: nil
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp ash_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  rescue
    _ -> "update failed"
  end

  defp ash_error_message(err), do: inspect(err)
end
