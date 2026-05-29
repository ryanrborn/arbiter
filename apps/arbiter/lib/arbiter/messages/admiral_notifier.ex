defmodule Arbiter.Messages.AdmiralNotifier do
  @moduledoc """
  Auto-posts Admiral notifications on acolyte (polecat) lifecycle events, so the
  Admiral is informed without acolytes having to send messages by hand.

  Wired into `Arbiter.Polecat`'s terminal/await transitions. Each event maps to
  a durable `:notification` `Arbiter.Messages.Message` — the broadcast kind that
  feeds the Admiral's dashboard (`to_ref` nil, never "consumed"):

  | Event              | Body                                                  |
  |--------------------|-------------------------------------------------------|
  | completed          | `<title> completed in <duration>`                     |
  | failed             | `<title> failed after <duration> — exit code <N>`     |
  | awaiting_review    | `<title> opened MR <mr_ref> — awaiting review`        |

  Directive-closed events are intentionally **not** posted — too noisy.

  ## Reconciliation with the bead spec

  The originating bead (bd-25ftl0) imagined dedicated `:completion` / `:failure`
  kinds and a `to="admiral"` / `directive_ref=bead_id` shape. The Message
  resource that actually shipped (bd-bduz2k) settled on a leaner taxonomy:
  broadcast `:notification`s (the Admiral feed) vs. addressed mailbox kinds.
  We honour the realised design — every lifecycle auto-post is a
  `:notification` with `from_ref` set to the directive's bead id; the
  completed/failed/awaiting distinction lives in the subject + body.

  ## Configuration

  Gated per-workspace by `workspace.config["admiral_notifications"]`
  (default `true`). Set it to `false` on high-volume workspaces to silence the
  auto-posts.

  ## Failure handling

  Every entry point is best-effort: a missing workspace, a DB hiccup, or a
  payload bug is swallowed (with a debug breadcrumb) so notification work never
  disrupts the polecat lifecycle. Mirrors the contract of
  `Arbiter.Polecat.broadcast_lifecycle/2`.
  """

  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message

  @config_key "admiral_notifications"

  @typedoc """
  The subset of an `Arbiter.Polecat` snapshot this module reads. Passing the
  full snapshot map is fine — extra keys are ignored.
  """
  @type snapshot :: %{
          required(:bead_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:started_at) => DateTime.t() | nil,
          optional(:meta) => map() | nil
        }

  @doc "Post the `:completed` lifecycle notification. Best-effort, returns `:ok`."
  @spec completed(snapshot()) :: :ok
  def completed(snapshot), do: post(:completed, snapshot)

  @doc "Post the `:failed` lifecycle notification. Best-effort, returns `:ok`."
  @spec failed(snapshot()) :: :ok
  def failed(snapshot), do: post(:failed, snapshot)

  @doc "Post the `:awaiting_review` lifecycle notification. Best-effort, returns `:ok`."
  @spec awaiting_review(snapshot()) :: :ok
  def awaiting_review(snapshot), do: post(:awaiting_review, snapshot)

  # ---- core ---------------------------------------------------------------

  # A notification must be scoped to a workspace (Message.workspace_id is
  # required), so a polecat with no workspace_id has nowhere to post.
  defp post(event, %{workspace_id: ws_id} = snapshot) when is_binary(ws_id) do
    if enabled?(ws_id) do
      Message.notify(build(event, snapshot))
    end

    :ok
  rescue
    e ->
      Logger.debug("AdmiralNotifier.post/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  defp post(_event, _snapshot), do: :ok

  # ---- payload construction ----------------------------------------------

  defp build(:completed, %{bead_id: bead_id} = snapshot) do
    base(bead_id, snapshot, "completed", fn title ->
      "#{title} completed in #{format_duration(elapsed_seconds(snapshot))}"
    end)
  end

  defp build(:failed, %{bead_id: bead_id} = snapshot) do
    duration = format_duration(elapsed_seconds(snapshot))

    base(bead_id, snapshot, "failed", fn title ->
      case exit_code(snapshot) do
        nil -> "#{title} failed after #{duration}"
        code -> "#{title} failed after #{duration} — exit code #{code}"
      end
    end)
  end

  defp build(:awaiting_review, %{bead_id: bead_id} = snapshot) do
    base(bead_id, snapshot, "awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil -> "#{title} — awaiting review"
        ref -> "#{title} opened MR #{ref} — awaiting review"
      end
    end)
  end

  defp base(bead_id, snapshot, subject_suffix, body_fun) do
    title = title_for(bead_id)

    %{
      workspace_id: snapshot.workspace_id,
      from_ref: bead_id,
      subject: "#{bead_id} #{subject_suffix}",
      body: body_fun.(title)
    }
  end

  # ---- lookups ------------------------------------------------------------

  # The bead's human-readable title, falling back to the bead id when the Issue
  # row can't be read (e.g. ad-hoc runs, or a workspace with no tracker row).
  defp title_for(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> bead_id
    end
  rescue
    _ -> bead_id
  end

  # Default-on: only an explicit `false` disables auto-posts. A missing or
  # unreadable workspace falls back to enabled.
  defp enabled?(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %{config: config}} -> Map.get(config || %{}, @config_key, true) != false
      _ -> true
    end
  rescue
    _ -> true
  end

  defp exit_code(%{meta: meta}) when is_map(meta), do: Map.get(meta, :exit_status)
  defp exit_code(_), do: nil

  defp mr_ref(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :mr_ref) || Map.get(meta, :mr_url)

  defp mr_ref(_), do: nil

  # ---- formatting ---------------------------------------------------------

  defp elapsed_seconds(%{started_at: %DateTime{} = started_at}),
    do: max(DateTime.diff(DateTime.utc_now(), started_at), 0)

  defp elapsed_seconds(_), do: 0

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)

    case rem(seconds, 60) do
      0 -> "#{minutes}m"
      rest -> "#{minutes}m #{rest}s"
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)

    case div(rem(seconds, 3600), 60) do
      0 -> "#{hours}h"
      minutes -> "#{hours}h #{minutes}m"
    end
  end
end
