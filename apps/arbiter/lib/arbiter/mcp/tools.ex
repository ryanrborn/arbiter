defmodule Arbiter.MCP.Tools do
  @moduledoc """
  The Phase 1 `Arbiter.MCP` tool handlers — the agent-native route back into the
  domain. Each handler calls Ash directly (the same actions the REST controllers
  and `arb` subcommands take) and returns plain, JSON-friendly maps.

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
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message

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
