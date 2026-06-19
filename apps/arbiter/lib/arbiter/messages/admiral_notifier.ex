defmodule Arbiter.Messages.AdmiralNotifier do
  @moduledoc """
  Auto-posts Admiral notifications on worker (worker) lifecycle events, so the
  Admiral is informed without workers having to send messages by hand.

  Wired into `Arbiter.Worker`'s terminal/await transitions. Each event maps to
  a durable `:notification` `Arbiter.Messages.Message` — the broadcast kind that
  feeds the Admiral's dashboard (`to_ref` nil, never "consumed"):

  | Event                | Body                                                       |
  |----------------------|------------------------------------------------------------|
  | completed            | `<title> completed in <duration>`                          |
  | failed               | `<title> failed after <duration> — exit code <N>`          |
  | awaiting_review      | `<title> opened MR <mr_ref> — awaiting review`             |
  | awaiting_review_stuck| `<title> stuck at awaiting_review (MR <mr_ref>) — escalated` |

  Directive-closed events are intentionally **not** posted — too noisy.

  ## Actionable escalations (`acolyte_stopped`, `preflight_failed`)

  A dead/stopped worker (token exhaustion, crash, external kill, auth expiry)
  or a failed pre-flight auth probe is not just dashboard noise — it needs the
  operator to *act* (re-authenticate, top up credits, re-dispatch). Those go out as
  addressed `:escalation` **mailbox** messages (`to_ref: "admiral"`,
  `directive_ref: <bead>`) so they land in `arb inbox` rather than scrolling off
  the broadcast feed. The classified cause + remediation
  (`Arbiter.Worker.StopReason`) is baked into the subject/body. See bd-awi4nw.

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
  disrupts the worker lifecycle. Mirrors the contract of
  `Arbiter.Worker.broadcast_lifecycle/2`.
  """

  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker.StopReason

  @config_key "admiral_notifications"

  @typedoc """
  The subset of an `Arbiter.Worker` snapshot this module reads. Passing the
  full snapshot map is fine — extra keys are ignored.
  """
  @type snapshot :: %{
          required(:bead_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:repo) => String.t() | nil,
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

  @doc """
  Post a `:pipeline_failed` notification. Best-effort, returns `:ok`. Fired by
  `Arbiter.Worker.Watchdog` when a CI pipeline fails and `watch_pipeline` is
  enabled. The bead is NOT failed — a human may force-merge or rerun.
  """
  @spec pipeline_failed(snapshot(), String.t() | nil) :: :ok
  def pipeline_failed(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:pipeline_failed, snapshot)
  end

  @doc """
  Post the `:awaiting_review_stuck` watchdog notification. Best-effort, returns
  `:ok`. Fired by `Arbiter.Worker.Watchdog` when a worker has been parked at
  `:awaiting_review` past its poll cap without a terminal MR outcome — so a
  silent hang surfaces to the operator instead of waiting forever (bd-66ey1o).
  """
  @spec awaiting_review_stuck(snapshot(), String.t() | nil) :: :ok
  def awaiting_review_stuck(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:awaiting_review_stuck, snapshot)
  end

  @doc """
  Escalate a stopped/dead worker to the Admiral (bd-awi4nw).

  Unlike the lifecycle `:notification`s above, this is an addressed
  `:escalation` **mailbox** message (`to_ref: "admiral"`) so it surfaces in
  `arb inbox` as an actionable item. The `Arbiter.Worker.StopReason` carries
  the classified cause + remediation; the subject names the bead + cause and
  the body spells out the repo, last activity, exit code, and fix. Best-effort,
  returns `:ok`.
  """
  @spec acolyte_stopped(snapshot(), StopReason.t()) :: :ok
  def acolyte_stopped(snapshot, %StopReason{} = reason),
    do: escalate(:acolyte_stopped, snapshot, reason)

  @doc """
  Escalate a failed pre-flight auth probe to the Admiral (bd-awi4nw).

  Fired by `Arbiter.Worker.Dispatch` when the agent CLI fails its cheap
  token-validity probe *before* any worker is dispatched — so a wave of spawns
  that would all 401 is refused up front and the operator is told to
  re-authenticate. Same addressed `:escalation` shape as `acolyte_stopped/2`.
  Best-effort, returns `:ok`.
  """
  @spec preflight_failed(snapshot(), StopReason.t()) :: :ok
  def preflight_failed(snapshot, %StopReason{} = reason),
    do: escalate(:preflight_failed, snapshot, reason)

  @doc """
  Escalate a proactively-detected credential expiry to the Admiral (bd-5wchp1).

  Fired by `Arbiter.Agents.CredentialWatchdog` when a periodic liveness probe
  detects that credentials are expired *before* any worker has been dispatched
  or failed. Unlike `acolyte_stopped/2` and `preflight_failed/2`, this has no
  associated bead — it names the adapter that failed instead.

  `snapshot` must contain `:workspace_id`; `adapter` is the module whose probe
  failed. Same addressed `:escalation` shape as the other escalations.
  Best-effort, returns `:ok`.
  """
  @spec credential_expired(%{workspace_id: String.t()}, module(), StopReason.t()) :: :ok
  def credential_expired(%{workspace_id: ws_id} = snapshot, adapter, %StopReason{} = reason)
      when is_binary(ws_id) and is_atom(adapter) do
    snapshot_with_adapter = Map.put(snapshot, :adapter, adapter)
    escalate(:credential_expired, snapshot_with_adapter, reason)
  end

  def credential_expired(_snapshot, _adapter, _reason), do: :ok

  @doc """
  Escalate a failed external-tracker sync to the Admiral (bd-c4cfuv).

  Fired by `Arbiter.Trackers.Sync` / `Arbiter.Beads.Issue.Changes.SyncTracker`
  when a lifecycle transition (dispatch → In Progress, PR-open → In Code Review,
  merge → Done, …) can't be resolved or fails on the wire. The original
  incident (VR-17911) was invisible precisely because such failures were
  swallowed; this surfaces a `status_map`/workflow mismatch as an actionable
  inbox item instead. Best-effort, returns `:ok`.

  `snapshot` carries `:bead_id` + `:workspace_id` (and optionally
  `:tracker_type` / `:tracker_ref`); `event` is the lifecycle atom; `reason` is
  the adapter's error term.
  """
  @spec tracker_sync_failed(map(), atom(), term()) :: :ok
  def tracker_sync_failed(%{workspace_id: ws_id} = snapshot, event, reason)
      when is_binary(ws_id) do
    bead_id = Map.get(snapshot, :bead_id, "system")
    tracker = Map.get(snapshot, :tracker_type)
    ref = Map.get(snapshot, :tracker_ref)

    subject = "#{bead_id} tracker sync failed — #{event}"

    body =
      [
        "Failed to sync #{title_for(bead_id)} to its external tracker on the " <>
          "`#{event}` lifecycle event.",
        tracker && "Tracker: #{tracker}#{ref && " #{ref}"}",
        "Error: #{describe_reason(reason)}",
        "This usually means the workspace `status_map` / `transition_graph` " <>
          "doesn't match the tracker's real workflow. Reconcile the config " <>
          "(see Arbiter.Trackers.Jira.Config) and re-run the sync."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: bead_id,
      workspace_id: ws_id,
      directive_ref: bead_id,
      subject: subject,
      body: body
    })

    :ok
  rescue
    e ->
      Logger.debug("AdmiralNotifier.tracker_sync_failed/3 swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def tracker_sync_failed(_snapshot, _event, _reason), do: :ok

  defp describe_reason(%{__struct__: _, message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason), do: inspect(reason)

  # ---- core ---------------------------------------------------------------

  # A notification must be scoped to a workspace (Message.workspace_id is
  # required), so a worker with no workspace_id has nowhere to post.
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

  # Actionable escalations are addressed mailbox messages (not broadcast
  # notifications) so they queue in `arb inbox` for the Admiral. They are NOT
  # gated by the `admiral_notifications` toggle — silencing routine completion
  # noise must never silence a "your credentials expired" alarm. A worker with
  # no workspace_id has nowhere to post (Message.workspace_id is required).
  defp escalate(event, %{workspace_id: ws_id} = snapshot, %StopReason{} = reason)
       when is_binary(ws_id) do
    {subject, body} = escalation_payload(event, snapshot, reason)

    Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: Map.get(snapshot, :bead_id, "system"),
      workspace_id: ws_id,
      directive_ref: Map.get(snapshot, :bead_id),
      subject: subject,
      body: body
    })

    :ok
  rescue
    e ->
      Logger.debug("AdmiralNotifier.escalate/3 swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate(_event, _snapshot, _reason), do: :ok

  defp escalation_payload(:credential_expired, snapshot, %StopReason{} = reason) do
    adapter = Map.get(snapshot, :adapter)
    adapter_label = if adapter, do: inspect(adapter), else: "agent"
    short_name = if adapter, do: adapter |> Module.split() |> List.last(), else: "Agent"

    subject = "#{short_name} credentials expired — proactive detection"

    body =
      [
        "Proactive credential probe: #{adapter_label} failed authentication.",
        reason.summary,
        reason.remediation && "Remediation: #{reason.remediation}",
        "Note: new worker dispatches for this adapter are suspended until credentials are restored."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  defp escalation_payload(event, %{bead_id: bead_id} = snapshot, %StopReason{} = reason) do
    verb =
      case event do
        :acolyte_stopped -> "stopped"
        :preflight_failed -> "pre-flight auth failed"
      end

    subject = "#{bead_id} #{verb} — #{StopReason.label(reason)}"

    lead =
      case event do
        :acolyte_stopped ->
          "Worker for #{title_for(bead_id)} stopped: #{reason.summary}."

        :preflight_failed ->
          "Refused to dispatch #{title_for(bead_id)} — agent pre-flight auth probe failed: " <>
            "#{reason.summary}."
      end

    body =
      [
        lead,
        "Bead: #{bead_id}",
        "Repo: #{repo(snapshot)}",
        exit_line(reason),
        activity_line(snapshot),
        reason.remediation && "Remediation: #{reason.remediation}",
        resume_hint(event, bead_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  # bd-auma3z: a stopped worker's worktree (committed/uncommitted
  # progress) is preserved, so the operator can continue rather than re-dispatching
  # from scratch. Offer the resume verb right in the escalation. Only for
  # `:acolyte_stopped` — a `:preflight_failed` refusal happens before any work,
  # so there is no worktree to resume.
  defp resume_hint(:acolyte_stopped, bead_id),
    do: "Resume: run `arb worker resume #{bead_id}` to continue from the preserved worktree."

  defp resume_hint(_event, _bead_id), do: nil

  defp repo(%{repo: repo}) when is_binary(repo) and repo != "", do: repo
  defp repo(_), do: "unknown"

  defp exit_line(%StopReason{exit_status: nil, signal: nil}), do: nil
  defp exit_line(%StopReason{exit_status: nil}), do: nil

  defp exit_line(%StopReason{exit_status: code, signal: nil}),
    do: "Exit code: #{code}"

  defp exit_line(%StopReason{exit_status: code, signal: sig}),
    do: "Exit code: #{code} (signal #{sig})"

  defp activity_line(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{label: label} when is_binary(label) -> "Last activity: #{label}"
      label when is_binary(label) and label != "" -> "Last activity: #{label}"
      _ -> nil
    end
  end

  defp activity_line(_), do: nil

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

  defp build(:pipeline_failed, %{bead_id: bead_id} = snapshot) do
    base(bead_id, snapshot, "CI pipeline failed", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} — CI pipeline failed (parked; human action required)"

        ref ->
          "#{title} MR #{ref} — CI pipeline failed (parked; human action required)"
      end
    end)
  end

  defp build(:awaiting_review_stuck, %{bead_id: bead_id} = snapshot) do
    base(bead_id, snapshot, "stuck awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} stuck at awaiting_review — escalated (no terminal MR outcome)"

        ref ->
          "#{title} stuck at awaiting_review (MR #{ref}) — escalated (no terminal MR outcome)"
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
