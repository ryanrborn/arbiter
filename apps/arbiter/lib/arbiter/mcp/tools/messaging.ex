defmodule Arbiter.MCP.Tools.Messaging do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for task/coordinator mailboxes and
  notifications: `inbox_check` / `coordinator_inbox` / `message_send` /
  `notify_list`. Split out of `Arbiter.MCP.Tools` (see its moduledoc) —
  called back into for the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Messages.Message

  @message_kinds_mcp ~w(notification completion failure escalation info)a

  # ---- inbox_check --------------------------------------------------------

  @doc """
  The mailbox for a task — the structured replacement for `arb inbox <task>`.
  Worker: its own task. Coordinator: the `task_id` argument, within its workspace.

  Two states:
  - `state: "unread"` (default): unread messages, marked read on return.
  - `state: "outstanding"`: read-but-uncleared messages; pure read, no mutations.
  """
  @spec inbox_check(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def inbox_check(%Scope{} = scope, args) do
    state = Tools.fetch_string(args, "state") || "unread"

    with :ok <- validate_state(state),
         {:ok, to_ref} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- Tools.fetch_task(scope, args, to_ref) do
      case state do
        "unread" ->
          messages = Message.inbox(to_ref, workspace_id: task.workspace_id)
          _ = Enum.each(messages, &Message.mark_read/1)

          {:ok,
           %{
             task_id: to_ref,
             messages: Enum.map(messages, &serialize_message/1),
             count: length(messages)
           }}

        "outstanding" ->
          messages = Message.outstanding(to_ref, workspace_id: task.workspace_id)

          {:ok,
           %{
             task_id: to_ref,
             messages: Enum.map(messages, &serialize_message/1),
             count: length(messages)
           }}
      end
    end
  end

  # ---- coordinator_inbox --------------------------------------------------

  @doc """
  The coordinator escalation mailbox for the bound workspace — the structured
  replacement for `arb message inbox` / `arb inbox`. Coordinator only; the
  worker tier is denied at the catalog level.

  Lists messages where `to_ref == "coordinator"` in the workspace. Two states:
  - `state: "unread"` (default): unread messages, marks them read on return,
    and optionally soft-clears the outstanding tail (mirrors `arb inbox clear`).
  - `state: "outstanding"`: read-but-uncleared messages; pure read, no mutations.

  `state: "outstanding"` and `clear: true` are mutually exclusive and will
  return an error.
  """
  @spec coordinator_inbox(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox(%Scope{} = scope, args) do
    state = Tools.fetch_string(args, "state") || "unread"

    with :ok <- validate_state(state),
         {:ok, clear} <- Tools.fetch_bool(args, "clear", false),
         :ok <- validate_state_and_clear_combo(state, clear),
         {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      ref = Message.coordinator_ref()

      case state do
        "unread" ->
          messages = Message.inbox(ref, workspace_id: ws_id)
          _ = Enum.each(messages, &Message.mark_read/1)

          {deleted_read, deleted_unread, remaining_unread} =
            if clear do
              {:ok, dr, du, ru} = Message.clear_read(ref, workspace_id: ws_id)
              {dr, du, ru}
            else
              {0, 0, 0}
            end

          {:ok,
           %{
             messages: Enum.map(messages, &serialize_message/1),
             count: length(messages),
             deleted_read: deleted_read,
             deleted_unread: deleted_unread,
             remaining_unread: remaining_unread
           }}

        "outstanding" ->
          messages = Message.outstanding(ref, workspace_id: ws_id)

          {:ok,
           %{
             messages: Enum.map(messages, &serialize_message/1),
             count: length(messages)
           }}
      end
    end
  end

  defp validate_state(state) when state in ["unread", "outstanding"] do
    :ok
  end

  defp validate_state(state) do
    {:error, {:invalid_args, "state must be \"unread\" or \"outstanding\", got \"#{state}\""}}
  end

  defp validate_state_and_clear_combo("outstanding", true) do
    {:error, {:invalid_args, "clear: true cannot be combined with state: \"outstanding\""}}
  end

  defp validate_state_and_clear_combo(_state, _clear) do
    :ok
  end

  # ---- message_send -------------------------------------------------------

  @doc """
  Send a message to a task's mailbox — the structured replacement for
  `arb message <task> <text>`. Available to **both** tiers, with the envelope
  set from the scope so the sender identity cannot be spoofed:

    * a **coordinator** sends a `:direction` from `"coordinator"` down to any
      task in its workspace;
    * a **worker** raises a `:flag` from its own bound task to a sibling.

  `workspace_id` is pinned to the recipient task's own workspace (a worker to
  its bound workspace), so a message can only ever be created alongside its
  recipient. Backs onto `Messages.send_mail/1`.
  """
  @spec message_send(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def message_send(%Scope{} = scope, args) do
    with {:ok, to_ref} <- Tools.require_string(args, "task_id"),
         {:ok, body} <- Tools.require_string(args, "body"),
         {:ok, ws_id} <- message_workspace(scope, args, to_ref),
         {:ok, kind} <- validate_message_kind(Tools.fetch_string(args, "kind")) do
      attrs =
        scope
        |> message_envelope(ws_id, to_ref, kind)
        |> Map.put(:body, body)
        |> Tools.maybe_put(:subject, Tools.fetch_string(args, "subject"))
        |> Tools.maybe_put(
          :task_ref,
          Tools.fetch_string(args, "task_ref") || Tools.fetch_string(args, "directive_ref")
        )

      case Message.send_mail(attrs) do
        {:ok, message} -> {:ok, serialize_message(message)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # The workspace a message lands in. A worker is pinned to its bound workspace.
  # A coordinator infers it from the recipient task itself (entity inference,
  # honoring an explicit `workspace` arg), which also validates the recipient
  # exists and is reachable by the scope.
  defp message_workspace(%Scope{tier: :worker, workspace_id: ws_id}, _args, _to_ref),
    do: {:ok, ws_id}

  defp message_workspace(%Scope{tier: :coordinator} = scope, args, to_ref) do
    with {:ok, task} <- Tools.fetch_task(scope, args, to_ref), do: {:ok, task.workspace_id}
  end

  # The sender identity + kind are derived from the scope, never the client: a
  # coordinator directs (`from: "coordinator"`); a worker flags from its own
  # bound task. Both are pinned to the resolved workspace. When kind is
  # explicitly provided, it overrides the auto-derived default.
  defp message_envelope(%Scope{tier: :coordinator}, ws_id, to_ref, nil) do
    %{
      kind: :direction,
      workspace_id: ws_id,
      from_ref: "coordinator",
      to_ref: to_ref,
      task_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :coordinator}, ws_id, to_ref, kind) when is_atom(kind) do
    %{
      kind: kind,
      workspace_id: ws_id,
      from_ref: "coordinator",
      to_ref: to_ref,
      task_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :worker, task_id: task_id}, ws_id, to_ref, nil) do
    %{
      kind: :flag,
      workspace_id: ws_id,
      from_ref: task_id,
      to_ref: to_ref,
      task_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :worker, task_id: task_id}, ws_id, to_ref, kind)
       when is_atom(kind) do
    %{
      kind: kind,
      workspace_id: ws_id,
      from_ref: task_id,
      to_ref: to_ref,
      task_ref: to_ref
    }
  end

  # Validate and convert message kind from string to atom. Returns {:ok, nil}
  # if not specified (use auto-derived kind), or {:ok, atom} if valid, or
  # {:error, {_, msg}} if invalid.
  defp validate_message_kind(nil), do: {:ok, nil}

  defp validate_message_kind(kind_str) when is_binary(kind_str) do
    case Tools.to_allowed_atom(kind_str, @message_kinds_mcp) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "invalid kind #{inspect(kind_str)}"}}
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
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, limit} <- Tools.optional_integer(args, "limit") do
      notifications =
        (limit || 20)
        |> Message.recent_notifications(workspace_id: ws_id)
        |> Enum.map(&serialize_message/1)

      {:ok, %{notifications: notifications, count: length(notifications)}}
    end
  end

  defp serialize_message(%Message{} = m) do
    %{
      id: m.id,
      kind: Tools.to_str(m.kind),
      from_ref: m.from_ref,
      to_ref: m.to_ref,
      subject: m.subject,
      body: m.body,
      task_ref: m.task_ref,
      directive_ref: m.directive_ref,
      read_at: Tools.iso(m.read_at),
      cleared_at: Tools.iso(m.cleared_at),
      inserted_at: Tools.iso(m.inserted_at)
    }
  end
end
