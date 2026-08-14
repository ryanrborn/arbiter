defmodule Arbiter.Reviews.PrStatePoller do
  @moduledoc """
  Background job that keeps `ExternalReview` records' `pr_state` fresh
  (bd-3jjk0e), independent of any open dashboard.

  Before this, pr_state was resolved *only* lazily while a dashboard LiveView
  was mounted — so a PR that merged/closed while nobody was watching kept a
  stale `open` (or a frozen `unknown`) forever. This singleton GenServer runs on
  a recurring timer, walks the non-terminal records (per
  `Arbiter.Reviews.PrState.needs_refresh?/1`), and re-resolves each one, so the
  dashboard is now a *reader* of pr_state rather than its only writer.

  Terminal states (`merged` / `closed` / `gone` / `n/a`) are skipped, so the
  poll set shrinks to genuinely in-flight PRs. A transient failure leaves a row
  `unknown` and it is retried on a later cycle; a hard 404 lands on the terminal
  `gone` and drops out of the set.

  ## Per-record backoff (bd-7qgxf9)

  "Non-terminal" is a much larger set than "in flight". A long-lived install
  accumulates review records whose PR is simply still `open` — nobody is
  waiting on them and nothing about them is going to change this minute — plus
  rows parked at `unknown` because a token blip failed them once. Re-resolving
  every one of them on every cycle made this poller's cost a function of
  *history*, flat at one call per record per minute forever: ~30 such records
  is the ~1,776 GitHub calls/hour a completely quiet fleet was measured
  burning, roughly a third of the account-wide 5,000/hr budget that GitHub
  meters per *user* rather than per token.

  So each record carries its own cadence instead of sharing one global tick:

    * a check that finds the state **unchanged** doubles that record's personal
      interval — `interval_ms`, 2×, 4×, … up to `:backoff_ceiling_ms`;
    * a check that finds it **changed** resets to `interval_ms`, so a PR that
      is actually moving is followed closely again on the very next cycle;
    * a check that **fails** counts as unchanged, which is what finally puts a
      permanently-`unknown` row on a decaying retry instead of a hot loop.

  A settled record therefore costs ~6 calls in its first hour and one per
  ceiling thereafter, and the cost of an idle installation decays toward zero
  no matter how much history it carries. The cadence lives in this GenServer's
  memory rather than on the row: a restart is worth one full re-sweep (which
  also re-verifies everything after downtime) and then decays again in minutes,
  which is not worth a migration or a DB write per skipped record.

  Cycles are additionally **budgeted** at `:max_checks_per_cycle` records,
  most-overdue first, so a large first sweep after a restart is spread over
  several cycles rather than landing as one spike; ordering by due time means
  no record starves.

  ## Configuration

  Via `config :arbiter, :pr_state_poller`:

    * `:enabled`              — master switch (default `true`; `false` in test,
                                where tests drive `poll/1` synchronously).
    * `:interval_ms`          — cycle interval, and the base of each record's
                                backoff (default 60 000).
    * `:fetch_limit`          — max records scanned per cycle (default 500).
    * `:backoff_ceiling_ms`   — longest a settled record's interval may grow to
                                (default 3 600 000, one hour).
    * `:max_checks_per_cycle` — max records actually re-resolved per cycle
                                (default 25).
  """

  use GenServer

  require Logger
  require Ash.Query

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Reviews.{PrState, Record}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.PatrolPacing

  @default_interval_ms 60_000
  @default_fetch_limit 500
  @default_backoff_ceiling_ms 60 * 60_000
  @default_max_checks_per_cycle 25

  # ---- public API ----------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one poll cycle synchronously and wait for it to complete.

  Intended for tests (and manual triggering); the periodic timer calls the same
  cycle. Returns `:ok`.
  """
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      fetch_limit: cfg(:fetch_limit, opts, @default_fetch_limit),
      backoff_ceiling_ms: cfg(:backoff_ceiling_ms, opts, @default_backoff_ceiling_ms),
      max_checks_per_cycle: cfg(:max_checks_per_cycle, opts, @default_max_checks_per_cycle),
      # Injectable so backoff growth is testable without sleeping through it.
      clock_fun: Keyword.get(opts, :clock_fun, &DateTime.utc_now/0),
      # record_id => %{due_at: DateTime.t(), streak: non_neg_integer(),
      #                last_state: String.t() | nil}
      cadence: %{}
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {:reply, :ok, run_cycle(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    state = run_cycle(state)
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals -----------------------------------------------------------

  # All GitHub traffic this cycle issues is background (bd-b88l3l): this poller
  # runs unattended on a timer and must yield to — and never starve —
  # foreground work like a deploy or a PR merge. `with_priority/3` tags the
  # current process for the duration of the cycle; the GitHub clients read
  # that ambient class at their request seam. Runs synchronously in the
  # poller process, so the tag applies. The second argument names this
  # subsystem in the limiter's periodic report line (bd-7qgxf9).
  defp run_cycle(state) do
    Limiter.with_priority(:background, :pr_state_poller, fn -> run_cycle_body(state) end)
  end

  # Resolve pr_state for the non-terminal records that are *due* this cycle, and
  # return the state with each checked record's next due time folded in.
  # Best-effort throughout: a DB read failure yields an empty set, and each
  # record is resolved under its own rescue so one bad row never aborts the
  # cycle.
  defp run_cycle_body(state) do
    now = state.clock_fun.()
    records = stale_records(state.fetch_limit)

    # Prune first, against the full non-terminal set: a record that reached a
    # terminal state (or was deleted) is gone for good, and leaving its cadence
    # entry behind would grow this map without bound over the process's life.
    state = prune_cadence(state, records)

    due =
      records |> Enum.filter(&due?(state, &1, now)) |> Enum.sort_by(&due_at(state, &1), DateTime)

    case Enum.take(due, state.max_checks_per_cycle) do
      [] ->
        state

      batch ->
        workspaces_by_id = workspaces_by_id()

        Enum.reduce(batch, state, fn record, acc ->
          workspace = Map.get(workspaces_by_id, record.workspace_id)
          resolved = PrState.resolve_and_persist(record, workspace)
          record_outcome(acc, record, resolved, now)
        end)
    end
  rescue
    e ->
      Logger.debug("PrStatePoller cycle swallowed: #{Exception.message(e)}")
      state
  end

  # A record with no cadence entry yet — first sight, or first cycle after a
  # restart — is due immediately.
  defp due?(state, record, now) do
    case Map.fetch(state.cadence, record.id) do
      {:ok, %{due_at: due_at}} -> DateTime.compare(now, due_at) != :lt
      :error -> true
    end
  end

  # Most-overdue first, so the per-cycle budget can never starve a record: an
  # unchecked one only gets further past due, which moves it up the order.
  defp due_at(state, record) do
    case Map.fetch(state.cadence, record.id) do
      {:ok, %{due_at: due_at}} -> due_at
      # Never seen: sorts ahead of anything with a real due time.
      :error -> ~U[1970-01-01 00:00:00Z]
    end
  end

  # Fold one check's outcome into the record's cadence. An unchanged state (or a
  # failed check, which tells us nothing new) grows the streak; a real
  # transition resets it so the record is followed closely while it moves.
  defp record_outcome(state, record, resolved, now) do
    previous = Map.get(state.cadence, record.id, %{streak: 0, last_state: record.pr_state})

    {streak, last_state} =
      case resolved do
        {:ok, %{pr_state: new_state}} ->
          {if(new_state == previous.last_state, do: previous.streak + 1, else: 0), new_state}

        # A failed check is not evidence of a change — back off rather than
        # retry hot, which is what kept permanently-broken rows spinning.
        _ ->
          {previous.streak + 1, previous.last_state}
      end

    delay = PatrolPacing.idle_backoff_ms(streak, state.interval_ms, state.backoff_ceiling_ms)

    entry = %{
      due_at: DateTime.add(now, delay, :millisecond),
      streak: streak,
      last_state: last_state
    }

    put_in(state.cadence[record.id], entry)
  end

  defp prune_cadence(%{cadence: cadence} = state, _records) when map_size(cadence) == 0, do: state

  defp prune_cadence(state, records) do
    live = MapSet.new(records, & &1.id)
    %{state | cadence: Map.filter(state.cadence, fn {id, _} -> MapSet.member?(live, id) end)}
  end

  defp stale_records(limit) do
    Record
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.filter(&PrState.needs_refresh?/1)
  rescue
    _ -> []
  end

  defp workspaces_by_id do
    Workspace
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :poll, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case get_in(Application.get_env(:arbiter, :pr_state_poller, []), [key]) do
          nil -> default
          val -> val
        end
    end
  end
end
