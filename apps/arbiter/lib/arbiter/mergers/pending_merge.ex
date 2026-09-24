defmodule Arbiter.Mergers.PendingMerge do
  @moduledoc """
  The durable record of an approved merge that has not happened yet
  (bd-a370ak / #2002).

  ## Problem this solves

  The merge decision for an approved PR used to live only in the memory of
  the `Arbiter.Worker.Watchdog` paired with the worker that opened it. The
  Watchdog monitors that worker and stops with it, so when the worker exited
  — its machine died, it was reaped, the server restarted — while the merge
  was waiting on something transient (CI still running, a draft PR, a 405/409
  from the forge), nothing ever looked at the PR again. Three approved, green,
  mergeable PRs sat for 17+ hours that way.

  ## The stamp

  Whenever a live Watchdog on an auto-merge lane reaches an *approved* verdict
  but does not merge on that poll, it stamps `issues.pending_merge` with:

    * `mr_ref` — the PR/MR the merge is for;
    * `reviewed_sha` — the reviewed baseline the Watchdog's stale-SHA guard was
      holding. For a ReviewGate lane that baseline otherwise exists only in the
      Watchdog's memory, and a retry without it would have no way to tell the
      approved commit apart from anything pushed afterwards;
    * `via_review_gate` — how the PR was approved (the forge never sees an
      in-process ReviewGate approval);
    * `reason` / `detail` — why the merge did not happen (`ci_pending`,
      `merge_failed`, ...), for the operator;
    * `since` — when this merge first started waiting;
    * `escalated_at` / `escalation_reason` — set once a retry has given up and
      paged the coordinator. A stamp carrying it is never retried again; the
      page is the hand-off to a human;
    * `notified_block` — a blocker the retry is *still waiting out* but has
      already told the coordinator about (red CI, `note_block/2`), so a restart
      or a re-armed retry does not tell them again. Unlike `escalated_at` it
      does not stop the retry.

  `Arbiter.Workflows.PendingMergeSweeper` re-arms a worker-less retry for any
  stamp nobody owns any more, and that retry runs the Watchdog's own merge
  guards (`Arbiter.Worker.Watchdog.start_retry/1`).

  The stamp is cleared by a merge, by a PR that closed unmerged, and by the
  task's `:close` / `:await_verification` actions.

  Every function here is best-effort: the stamp is written from the
  Watchdog's poll loop, and a DB hiccup there must never take the merge lane
  down with it.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Issue

  @type t :: %{
          mr_ref: String.t() | nil,
          reviewed_sha: String.t() | nil,
          via_review_gate: boolean(),
          reason: String.t() | nil,
          detail: String.t() | nil,
          since: String.t() | nil,
          escalated_at: String.t() | nil,
          escalation_reason: String.t() | nil,
          notified_block: String.t() | nil
        }

  # Merge-call errors that describe a PR state the forge expects to change on
  # its own: a 405 (still a draft, checks not yet reported), a 409 (the base or
  # head moved under the call), transport and 5xx failures, rate limiting.
  # Anything else — a 403, a 422, a missing PR, our own `:empty_net_diff`
  # refusal — will fail identically on every retry.
  @transient_error_kinds [:not_mergeable, :conflict, :network, :server_error, :rate_limited]

  @doc """
  Record (or refresh) the pending merge for `task_id`.

  `attrs` takes `:mr_ref`, `:reviewed_sha`, `:via_review_gate`, `:reason` and
  an optional `:detail`. `since` is preserved while the stamp still describes
  the same merge (same MR, same reviewed baseline); any fresh stamp clears a
  previous escalation, because a live Watchdog stamping again means somebody
  re-dispatched the work. A task that is already closed or parked at
  `:awaiting_verification` is left alone.
  """
  @spec stamp(String.t(), map()) :: :ok | {:error, term()}
  def stamp(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    with {:ok, %Issue{} = task} <- Ash.get(Issue, task_id) do
      if task.status in [:closed, :awaiting_verification] do
        :ok
      else
        write(task, build(get(task), attrs))
      end
    end
  rescue
    e -> swallow("stamp", task_id, Exception.message(e))
  catch
    :exit, reason -> swallow("stamp", task_id, inspect(reason))
  end

  @doc "Drop the pending merge for `task_id`, if it has one."
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(task_id) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{pending_merge: nil}} -> :ok
      {:ok, %Issue{} = task} -> write(task, nil)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> swallow("clear", task_id, Exception.message(e))
  catch
    :exit, reason -> swallow("clear", task_id, inspect(reason))
  end

  @doc """
  Latch the stamp as escalated: a retry gave up and paged the coordinator, so
  the sweeper must not re-arm it. Keeps the rest of the stamp for the operator.
  """
  @spec mark_escalated(String.t(), term()) :: :ok | {:error, term()}
  def mark_escalated(task_id, reason) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{pending_merge: %{} = raw} = task} ->
        write(
          task,
          Map.merge(stringify(raw), %{
            "escalated_at" => now(),
            "escalation_reason" => describe(reason)
          })
        )

      {:ok, %Issue{}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> swallow("mark_escalated", task_id, Exception.message(e))
  catch
    :exit, reason -> swallow("mark_escalated", task_id, inspect(reason))
  end

  @doc """
  Record that a retry told the coordinator it is waiting on `block` (e.g.
  `:ci_failed`) for this pending merge. `:first` when this is news — the caller
  sends the notice — and `:already` when the stamp already carries it, so the
  notice goes out once per pending merge however often the retry is re-armed.
  Also sets `reason` to the block, for the operator. A fresh `stamp/2` (a live
  Watchdog on the task again) starts a new episode and clears it.

  `{:error, _}` (no stamp, or a DB failure) means "don't notify now"; the next
  poll asks again.
  """
  @spec note_block(String.t(), atom()) :: :first | :already | {:error, term()}
  def note_block(task_id, block) when is_binary(task_id) and is_atom(block) do
    tag = Atom.to_string(block)

    case Ash.get(Issue, task_id) do
      {:ok, %Issue{pending_merge: %{} = raw} = task} ->
        raw = stringify(raw)

        if raw["notified_block"] == tag do
          :already
        else
          with :ok <- write(task, Map.merge(raw, %{"notified_block" => tag, "reason" => tag})),
               do: :first
        end

      {:ok, %Issue{}} ->
        {:error, :no_pending_merge}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> swallow("note_block", task_id, Exception.message(e))
  catch
    :exit, reason -> swallow("note_block", task_id, inspect(reason))
  end

  @doc "The pending merge a task carries, normalised, or `nil`."
  @spec get(Issue.t() | map() | nil) :: t() | nil
  def get(%{pending_merge: %{} = raw}) do
    raw = stringify(raw)

    %{
      mr_ref: raw["mr_ref"],
      reviewed_sha: raw["reviewed_sha"],
      via_review_gate: raw["via_review_gate"] == true,
      reason: raw["reason"],
      detail: raw["detail"],
      since: raw["since"],
      escalated_at: raw["escalated_at"],
      escalation_reason: raw["escalation_reason"],
      notified_block: raw["notified_block"]
    }
  end

  def get(_task), do: nil

  @doc "Whether a pending merge is still the fleet's to retry (not yet handed to a human)."
  @spec retryable?(t() | nil) :: boolean()
  def retryable?(%{mr_ref: ref, escalated_at: nil}) when is_binary(ref) and ref != "", do: true
  def retryable?(_pending), do: false

  @doc """
  Every open task carrying a pending merge, oldest stamp first. Tasks already
  closed or parked at `:awaiting_verification` are excluded — their PR merged.
  """
  @spec list_open() :: {:ok, [Issue.t()]} | {:error, term()}
  def list_open do
    Issue
    |> Ash.Query.filter(
      not is_nil(pending_merge) and status not in [:closed, :awaiting_verification]
    )
    |> Ash.Query.sort(updated_at: :asc)
    |> Ash.read()
  end

  @doc """
  Whether a merge-call error is one the forge is expected to clear on its own
  (see `@transient_error_kinds`). Adapter error structs are matched on
  `kind`; a crash or exit inside the adapter call counts as transient.
  """
  @spec transient_merge_error?(term()) :: boolean()
  def transient_merge_error?(%{kind: kind}) when kind in @transient_error_kinds, do: true
  def transient_merge_error?({:exit, _reason}), do: true
  def transient_merge_error?({:exception, _message}), do: true
  def transient_merge_error?(_reason), do: false

  @doc "A short, human-readable rendering of a reason term for the stamp."
  @spec describe(term()) :: String.t()
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)

  def describe(%{kind: kind} = err) do
    [Atom.to_string(kind), err |> Map.get(:status) |> to_s(), Map.get(err, :message)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  def describe(reason), do: reason |> inspect() |> String.slice(0, 200)

  # ---- internals ----------------------------------------------------------

  defp build(previous, attrs) do
    mr_ref = fetch(attrs, :mr_ref)
    reviewed = fetch(attrs, :reviewed_sha)

    since =
      case previous do
        %{mr_ref: ^mr_ref, reviewed_sha: ^reviewed, since: since} when is_binary(since) -> since
        _ -> now()
      end

    %{
      "mr_ref" => mr_ref,
      "reviewed_sha" => reviewed,
      "via_review_gate" => fetch(attrs, :via_review_gate) == true,
      "reason" => attrs |> fetch(:reason) |> to_s(),
      "detail" => attrs |> fetch(:detail) |> to_s(),
      "since" => since,
      "escalated_at" => nil,
      "escalation_reason" => nil,
      "notified_block" => nil
    }
  end

  defp write(task, value) do
    case Ash.update(task, %{pending_merge: value}, action: :set_pending_merge) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp to_s(nil), do: nil
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value) when is_atom(value) or is_integer(value), do: to_string(value)
  defp to_s(value), do: describe(value)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp swallow(op, task_id, message) do
    Logger.debug("PendingMerge.#{op} swallowed for task=#{task_id}: #{message}")
    {:error, message}
  end
end
