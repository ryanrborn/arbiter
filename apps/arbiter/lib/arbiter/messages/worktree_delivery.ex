defmodule Arbiter.Messages.WorktreeDelivery do
  @moduledoc """
  Delivers inbox messages to a running worker's worktree by appending to
  `.arbiter/INBOX` in the worktree root.

  Called from the `Message` resource's `create` after_action hook so every
  code path (REST, MCP, LiveView) gets delivery automatically.

  ## Delivery semantics

  - Only task-targeted message kinds trigger delivery (`:mailbox`, `:direction`,
    `:flag`). Coordinator-bound kinds (`:completion`, `:failure`, etc.) are skipped.
  - If no worker is running for the `to_ref`, delivery is a no-op.
  - If a worker is running but has no worktree (no `:worktree_path` in meta),
    delivery is a no-op.
  - Write failures are logged as warnings and do not propagate — delivery is
    best-effort and never blocks the message write.
  - Multiple messages arriving before the worker checks accumulate via appending.
    The worker is responsible for deleting the file on read (acknowledge
    semantics); a subsequent message then creates a fresh file.

  ## File format

  Each message is appended as:

      [2026-06-23T20:45:00Z]
      <body>
      ---

  """

  require Logger

  @task_inbox_kinds [:mailbox, :direction, :flag]

  @doc """
  Maybe write the message body to `.arbiter/INBOX` in the worker's worktree.
  Returns `:ok` unconditionally — delivery is best-effort.
  """
  @spec maybe_deliver(map()) :: :ok
  def maybe_deliver(%{kind: kind, to_ref: to_ref, body: body, inserted_at: inserted_at})
      when kind in @task_inbox_kinds and is_binary(to_ref) do
    case worktree_path_for(to_ref) do
      nil ->
        :ok

      path ->
        write_inbox(path, body, inserted_at)
    end
  end

  def maybe_deliver(_message), do: :ok

  # ---- private helpers -------------------------------------------------------

  defp worktree_path_for(task_id) do
    case Arbiter.Worker.state(task_id) do
      %{meta: meta} when is_map(meta) -> Map.get(meta, :worktree_path)
      _ -> nil
    end
  end

  defp write_inbox(worktree_path, body, inserted_at) do
    inbox_dir = Path.join(worktree_path, ".arbiter")
    inbox_file = Path.join(inbox_dir, "INBOX")
    timestamp = format_timestamp(inserted_at)
    entry = "[#{timestamp}]\n#{body}\n---\n"

    with :ok <- File.mkdir_p(inbox_dir),
         :ok <- File.write(inbox_file, entry, [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "WorktreeDelivery: failed to write INBOX at #{inbox_file}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
  defp format_timestamp(_), do: DateTime.to_iso8601(DateTime.utc_now())
end
