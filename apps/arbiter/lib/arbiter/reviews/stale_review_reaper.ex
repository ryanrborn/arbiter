defmodule Arbiter.Reviews.StaleReviewReaper do
  @moduledoc """
  Periodically transitions abandoned `ExternalReview` records out of
  `:running` (bd-4vc2bo).

  An external review is dispatched with a `Record` row created up front at
  `status: :running` (see `Arbiter.Reviews.ExternalReview`), then updated to a
  terminal status by the workflow when it finishes. If the reviewer process
  dies mid-flight — killed, crashed, host restart — nothing ever writes that
  terminal update, and the row is stuck `running` forever. That silently
  breaks `external_review_list(status: "running")` as a liveness signal: it
  reports work that is not actually happening.

  This is a flat wall-clock reaper, not a heartbeat: any `running` row older
  than `:timeout_ms` (measured from `started_at`) with no completion is
  presumed abandoned and flipped to `:failed`. A per-record heartbeat would
  be more precise — a repo-scope review can legitimately run much longer than
  a diff-scope one, and a fast flat timeout risks reaping something still
  genuinely in flight — but review `Record` rows carry no scope/progress
  signal to key a heartbeat off today. The default timeout is set generous
  enough to clear that gap; tightening it is a config change, not a code
  change.

  ## Configuration

  Via `config :arbiter, :stale_review_reaper`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `reap/1` synchronously).
    * `:interval_ms` — sweep cadence (default 900 000, 15 minutes).
    * `:timeout_ms`  — age past `started_at`, with no completion, before a
                       `:running` row is reaped (default 14 400 000, 4 hours).
    * `:fetch_limit` — max `:running` records scanned per sweep (default 500).
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Reviews.Record

  @default_interval_ms 15 * 60_000
  @default_timeout_ms 4 * 60 * 60_000
  @default_fetch_limit 500

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Reap every `:running` record whose `started_at` is older than `:timeout_ms`
  (default from config, overridable via opts — mainly for tests). Each match
  is transitioned to `:failed` with `failure_stage: "reaper"` and a
  `failure_reason` describing the deadline that tripped. Best-effort: a
  failure updating one record is logged and does not stop the sweep; a read
  failure is logged and the sweep is skipped this cycle.
  """
  @spec reap(keyword()) :: :ok
  def reap(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, cfg(:timeout_ms, @default_timeout_ms))
    fetch_limit = Keyword.get(opts, :fetch_limit, cfg(:fetch_limit, @default_fetch_limit))
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    Record
    |> Ash.Query.filter(status == :running and started_at < ^cutoff)
    |> Ash.Query.limit(fetch_limit)
    |> Ash.read!()
    |> Enum.each(&reap_one(&1, timeout_ms))

    :ok
  rescue
    e ->
      Logger.error("Arbiter.Reviews.StaleReviewReaper sweep failed: #{Exception.message(e)}")
      :ok
  end

  defp reap_one(record, timeout_ms) do
    attrs = %{
      status: :failed,
      completed_at: DateTime.utc_now(),
      failure_stage: "reaper",
      failure_reason:
        "reaped: no progress within #{timeout_ms}ms of dispatch — reviewer process " <>
          "presumed dead (bd-4vc2bo)"
    }

    case Ash.update(record, attrs, action: :complete) do
      {:ok, updated} ->
        broadcast_reaped(updated)

      {:error, error} ->
        Logger.error(
          "Arbiter.Reviews.StaleReviewReaper failed to reap #{record.id}: #{inspect(error)}"
        )
    end
  end

  defp broadcast_reaped(%Record{workspace_id: ws_id} = record) when is_binary(ws_id) do
    Arbiter.Events.broadcast(ws_id, "external_review", %{
      status: "failed",
      pr_ref: record.pr_ref,
      verdict: record.verdict,
      finding_count: record.finding_count,
      mode: record.mode,
      review_record_id: record.id,
      engagement_id: record.engagement_id
    })
  end

  defp broadcast_reaped(_record), do: :ok

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:reap, state) do
    reap()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :reap, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :stale_review_reaper, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
