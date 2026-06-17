defmodule Arbiter.MCP.Tools do
  @moduledoc """
  The `Arbiter.MCP` tool handlers — the agent-native route back into the domain.
  Each handler calls Ash directly (the same actions the REST controllers and
  `arb` subcommands take) and returns plain, JSON-friendly maps.

  Phase 1 ships the read tools plus the one narrowed polecat write
  (`bead_update_progress`); Phase 2 adds the coordinator-only mutating tools —
  `bead_create` / `bead_update` / `bead_close`, `dep_add` / `dep_remove`, the
  `convoy_*` family, `polecat_sling`, `polecat_message`, and `usage_summarize`
  (see `docs/mcp-server-design.md` §8). `polecat_sling` carries the
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
  alias Arbiter.Beads.Convoy
  alias Arbiter.Beads.ConvoyMembership
  alias Arbiter.Beads.Dependency
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat.Sling
  alias Arbiter.Usage

  require Ash.Query

  @progress_fields ~w(notes qa_notes deployment_notes)

  # ---- bead_show ----------------------------------------------------------

  @doc "Read a single bead. Polecat: its own bead only. Coordinator: any in its workspace."
  @spec bead_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_show(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, id) do
      {:ok, serialize_bead(issue)}
    end
  end

  # ---- bead_ready ---------------------------------------------------------

  @doc "List ready (unblocked, open) beads in the scope's workspace. Coordinator only."
  @spec bead_ready(Scope.t(), map()) :: {:ok, map()}
  def bead_ready(%Scope{workspace_id: ws_id}, _args) do
    beads =
      [workspace_id: ws_id]
      |> Issue.ready()
      |> Enum.map(&serialize_bead_summary/1)

    {:ok, %{beads: beads, count: length(beads)}}
  end

  # ---- convoy_status ------------------------------------------------------

  @doc """
  Convoy progress (open/closed member counts). Coordinator: any convoy in its
  workspace. Polecat: only a convoy its bound bead is a member of.
  """
  @spec convoy_status(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def convoy_status(%Scope{} = scope, args) do
    case fetch_string(args, "id") do
      nil ->
        {:error, {:invalid, "convoy_status requires a convoy `id`"}}

      id ->
        with {:ok, convoy} <- fetch_convoy(scope, id),
             :ok <- ensure_convoy_visible(scope, convoy) do
          {:ok, serialize_convoy(convoy)}
        end
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
    with {:ok, to_ref} <- resolve_bead_id(scope, args, "bead_id") do
      messages = Message.inbox(to_ref, workspace_id: scope.workspace_id)
      _ = Enum.each(messages, &Message.mark_read/1)

      {:ok,
       %{
         bead_id: to_ref,
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages)
       }}
    end
  end

  # ---- workspace_show -----------------------------------------------------

  @doc """
  The scope's own workspace: config, vernacular, and the resolved acolyte
  security posture. Always the bound workspace — the argument is ignored so a
  scope can never inspect another workspace.
  """
  @spec workspace_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_show(%Scope{workspace_id: ws_id}, _args) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, serialize_workspace(ws)}
      _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
    end
  end

  # ---- bead_update_progress ----------------------------------------------

  @doc """
  The polecat's one write: record `notes` / `qa_notes` / `deployment_notes` on
  its own bead (the structured replacement for `arb issue update <id>
  --qa-notes …`). It cannot flip status, reprioritize, or touch another bead.
  Coordinator: the same narrow write against any bead in its workspace.
  """
  @spec bead_update_progress(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_update_progress(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_bead_id(scope, args),
         {:ok, issue} <- fetch_bead(scope, id),
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
  Create a bead in the scope's workspace. Coordinator only. `workspace_id` is
  forced to the scope's workspace — a coordinator cannot create beads elsewhere.
  Backs onto `Ash.create(Issue, …)` (the same path `arb create` / the REST
  `POST /api/issues` take), so a workspace with a tracker configured still
  mirrors the new bead upstream.
  """
  @spec bead_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def bead_create(%Scope{workspace_id: ws_id}, args) do
    with {:ok, title} <- require_string(args, "title"),
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
         {:ok, issue} <- fetch_bead(scope, id),
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
         {:ok, issue} <- fetch_bead(scope, id),
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
         {:ok, _from_bead} <- fetch_bead(scope, from),
         {:ok, _to_bead} <- fetch_bead(scope, to) do
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
         {:ok, _from_bead} <- fetch_bead(scope, from),
         {:ok, _to_bead} <- fetch_bead(scope, to) do
      edges = find_dep_edges(from, to, type)
      _ = Enum.each(edges, &Ash.destroy!/1)
      {:ok, %{from_issue_id: from, to_issue_id: to, removed: length(edges)}}
    end
  end

  # ---- convoy_list --------------------------------------------------------

  @doc "List the convoys in the scope's workspace, with member counts. Coordinator only."
  @spec convoy_list(Scope.t(), map()) :: {:ok, map()}
  def convoy_list(%Scope{workspace_id: ws_id}, _args) do
    convoys =
      Convoy
      |> Ash.Query.filter(workspace_id == ^ws_id)
      |> Ash.read!(load: [:total_issues, :closed_issues])
      |> Enum.map(&serialize_convoy/1)

    {:ok, %{convoys: convoys, count: length(convoys)}}
  end

  # ---- convoy_create ------------------------------------------------------

  @doc """
  Create a convoy in the scope's workspace. Coordinator only. `workspace_id` is
  forced to the scope's workspace. Backs onto `Ash.create(Convoy, …)`.
  """
  @spec convoy_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def convoy_create(%Scope{workspace_id: ws_id}, args) do
    with {:ok, title} <- require_string(args, "title"),
         {:ok, attrs} <- collect_attrs(args, convoy_create_spec()) do
      attrs = attrs |> Map.put("title", title) |> Map.put("workspace_id", ws_id)

      case Ash.create(Convoy, attrs) do
        {:ok, convoy} -> {:ok, serialize_convoy(reload_convoy(convoy))}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- convoy_add_member --------------------------------------------------

  @doc """
  Attach a bead to a convoy (idempotent). Coordinator only. Both the convoy and
  the bead must live in the scope's workspace. Backs onto the
  `ConvoyMembership.:add` upsert.
  """
  @spec convoy_add_member(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def convoy_add_member(%Scope{} = scope, args) do
    with {:ok, convoy_id} <- require_string(args, "id"),
         {:ok, issue_id} <- require_string(args, "issue_id"),
         {:ok, convoy} <- fetch_convoy(scope, convoy_id),
         {:ok, _issue} <- fetch_bead(scope, issue_id) do
      case Ash.create(ConvoyMembership, %{convoy_id: convoy.id, issue_id: issue_id}, action: :add) do
        {:ok, _membership} -> {:ok, serialize_convoy(reload_convoy(convoy))}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- convoy_close -------------------------------------------------------

  @doc "Close a convoy in the scope's workspace. Coordinator only."
  @spec convoy_close(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def convoy_close(%Scope{} = scope, args) do
    with {:ok, convoy_id} <- require_string(args, "id"),
         {:ok, convoy} <- fetch_convoy(scope, convoy_id) do
      attrs = maybe_put(%{}, :reason, fetch_string(args, "reason"))

      case Ash.update(convoy, attrs, action: :close) do
        {:ok, closed} -> {:ok, serialize_convoy(reload_convoy(closed))}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- polecat_message ----------------------------------------------------

  @doc """
  Send a direction to a bead's mailbox (the structured replacement for
  `arb message <bead> <text>` from the coordinator side). Coordinator only.
  `workspace_id` is forced to the scope's workspace so a coordinator can only
  message within it. Backs onto `Messages.send_mail/1`.
  """
  @spec polecat_message(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_message(%Scope{workspace_id: ws_id}, args) do
    with {:ok, to_ref} <- require_string(args, "bead_id"),
         {:ok, body} <- require_string(args, "body") do
      attrs =
        %{
          kind: :direction,
          workspace_id: ws_id,
          from_ref: "coordinator",
          to_ref: to_ref,
          directive_ref: to_ref,
          body: body
        }
        |> maybe_put(:subject, fetch_string(args, "subject"))

      case Message.send_mail(attrs) do
        {:ok, message} -> {:ok, serialize_message(message)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
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
  so a chain of dispatches is tracked. Without `with_claude` the bead simply
  parks `:in_progress` (no agent spawned); with it, a worker session is started.
  Backs onto `Arbiter.Polecat.Sling.sling/2`.
  """
  @spec polecat_sling(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def polecat_sling(%Scope{} = scope, args) do
    with :ok <- ensure_can_sling(scope),
         :ok <- ensure_sling_depth(scope),
         {:ok, bead_id} <- resolve_bead_id(scope, args, "bead_id"),
         {:ok, _bead} <- fetch_bead(scope, bead_id) do
      case Sling.sling(bead_id, sling_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_sling(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, sling_error_message(reason)}}
      end
    end
  end

  # ---- usage_summarize ----------------------------------------------------

  @doc """
  Roll up the token/cost usage ledger for the scope's workspace. Coordinator
  only. `by` is required (one of `Arbiter.Usage.valid_groupings/0`); `since`
  (ISO-8601) and `limit` are optional. `workspace_id` is forced to the scope's
  workspace. Backs onto `Arbiter.Usage.summarize/1`.
  """
  @spec usage_summarize(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_summarize(%Scope{workspace_id: ws_id}, args) do
    with {:ok, by} <- require_enum(args, "by", Usage.valid_groupings()),
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

  # Fetch a bead and enforce workspace isolation. A bead in another workspace is
  # reported as not-found so existence does not leak across workspaces.
  defp fetch_bead(scope, id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{} = issue} ->
        if Scope.same_workspace?(scope, issue.workspace_id),
          do: {:ok, issue},
          else: {:error, {:not_found, "bead #{id} not found"}}

      _ ->
        {:error, {:not_found, "bead #{id} not found"}}
    end
  end

  defp fetch_convoy(scope, id) do
    case Ash.get(Convoy, id) do
      {:ok, %Convoy{} = convoy} ->
        if Scope.same_workspace?(scope, convoy.workspace_id) do
          load_convoy(convoy)
        else
          {:error, {:not_found, "convoy #{id} not found"}}
        end

      _ ->
        {:error, {:not_found, "convoy #{id} not found"}}
    end
  end

  defp load_convoy(convoy) do
    {:ok, Ash.load!(convoy, [:total_issues, :closed_issues, :issues])}
  rescue
    _ -> {:error, {:not_found, "convoy #{convoy.id} not found"}}
  end

  # A polecat may only see a convoy its bound bead belongs to. Coordinator sees
  # any convoy in the workspace (already gated by fetch_convoy).
  defp ensure_convoy_visible(%Scope{tier: :coordinator}, _convoy), do: :ok

  defp ensure_convoy_visible(%Scope{tier: :polecat, bead_id: bead_id}, convoy) do
    members = convoy.issues || []

    if Enum.any?(members, &(&1.id == bead_id)),
      do: :ok,
      else: {:error, {:unauthorized, "this polecat is not a member of convoy #{convoy.id}"}}
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
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string}
    ]
  end

  defp convoy_create_spec do
    [{"lifecycle", {:enum, Convoy.lifecycles()}}]
  end

  # ---- Phase 2 sling guardrail + opts (docs/mcp-server-design.md §4.3) ----

  defp ensure_can_sling(%Scope{can_sling: true}), do: :ok

  defp ensure_can_sling(%Scope{}),
    do: {:error, {:unauthorized, "this scope may not sling (can_sling is not set)"}}

  defp ensure_sling_depth(%Scope{depth: depth}) do
    max = MCP.max_depth()
    if depth < max, do: :ok, else: {:error, {:unauthorized, "sling depth limit (#{max}) reached"}}
  end

  # Map the tool's arguments onto `Sling.sling/2` opts, mirroring the REST
  # `POST /api/polecats/sling` contract: `with_claude` dispatches a real worker
  # session, otherwise the bead parks `:in_progress` (no Driver). The child
  # polecat's scope token is minted one level deeper (`depth + 1`).
  defp sling_opts(%Scope{depth: depth}, args) do
    base =
      [depth: depth + 1]
      |> maybe_put_kw(:rig, fetch_string(args, "rig"))
      |> maybe_put_kw(:model, fetch_string(args, "model"))

    case Map.get(args, "with_claude") do
      v when v in [true, "true"] -> Keyword.put(base, :start_claude, true)
      _ -> Keyword.put(base, :start_driver, false)
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

  defp reload_convoy(%Convoy{} = convoy), do: Ash.load!(convoy, [:total_issues, :closed_issues])

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
      assignee: i.assignee,
      tracker_type: to_str(i.tracker_type),
      tracker_ref: i.tracker_ref,
      pr_ref: i.pr_ref,
      target_branch: i.target_branch,
      workspace_id: i.workspace_id,
      closed_at: iso(i.closed_at),
      created_at: iso(i.created_at),
      updated_at: iso(i.updated_at)
    }
  end

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

  defp serialize_convoy(%Convoy{} = c) do
    total = calc(c.total_issues)
    closed = calc(c.closed_issues)

    %{
      id: c.id,
      title: c.title,
      status: to_str(c.status),
      lifecycle: to_str(c.lifecycle),
      total_issues: total,
      closed_issues: closed,
      open_issues: max(total - closed, 0),
      closed_reason: c.closed_reason,
      closed_at: iso(c.closed_at),
      workspace_id: c.workspace_id
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

  defp calc(n) when is_integer(n), do: n
  defp calc(_), do: 0

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
