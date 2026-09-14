defmodule Arbiter.Reviews.CoverageShadow do
  @moduledoc """
  P3 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.4/§6.3:
  **shadow mode**.

  `Arbiter.Worker.Watchdog` and `Arbiter.Workflows.MergeQueue` both keep
  deciding whether to merge exactly as they did before — on
  `issues.last_reviewed_sha`, through `Arbiter.Mergers.ReviewedSha` — and
  additionally hand their answer to `observe/1`, which computes
  `Arbiter.Reviews.Coverage.decide/3` over the same head and records whether
  the two agree. **The old answer is the one acted on.** Nothing in this
  module can change a merge decision; `observe/1` returns `:ok` for every
  input it is ever given, including ones whose `ctx` lookups raise.

  That is the whole point of the phase. P4 flips the read path over to
  `decide/3` behind `merge.coverage_enabled`, and P5/P6 then delete the latch,
  the suspension and the memo. Flipping on the strength of unit tests alone is
  exactly the move that produced chain A — four guards in nine days, each
  correct in isolation. So P3 buys the evidence first: run both predicates
  against real production traffic and count the disagreements.

  ## Reading the counter

  Two readers, because the coordinator's journal-grep habits break in release
  mode (debug logs are dropped) and an in-memory counter does not survive the
  restart that precedes the observation:

    * **Durable** — one `Arbiter.Events.Record` row per *distinct* observation,
      on topic `coverage_shadow`, carrying both answers. Read it over the API
      (`GET /events?subscribe=coverage_shadow&since=0`), or straight from
      SQLite:

          select json_extract(payload, '$.result') as result, count(*)
            from events where topic = 'coverage_shadow' group by result;

      "Zero disagreements over ≥20 merges" is `result = 'disagree'` absent from
      that grouping while `result = 'agree'` is ≥ 20. `disagreement_count/0`
      and `report/0` answer the same question from Elixir.

    * **Since boot** — `Arbiter.Reviews.CoverageShadow.Tally.snapshot/0`, which
      also counts the re-polls the event log deliberately collapses, plus the
      per-site and per-transition breakdown.

  A disagreement also logs exactly one `:warning` line (never `:debug` —
  release mode drops those) naming the site, task, MR, head, both answers and
  the new answer's reason.

  ## What shadow mode costs

  One forge round-trip per guarded-merge decision that reaches §3.2's rule 3 —
  the three-dot compare `ctx.fetch_diff` performs. Rules 0, 1 and 2 answer
  without it, so the healthy post-P1 path (a `:reviewed` row exists for the
  head the forge reports) adds no forge traffic at all. The paths that do pay
  are the ones where the head already differs from the stamp, which in the
  Watchdog already fetched two diffs of its own (`base_merge_only?/3`); the
  MergeQueue's stale-SHA retry (§2.3's M3, unbounded by design until P6) is
  the one place this is a genuinely new per-tick call. Both adapters route
  through `Arbiter.GitHub.Limiter`, and the phase is short-lived by
  construction — P4 replaces the double evaluation with a single one.

  ## Rule-3 `:mechanical` rows are NOT written in shadow mode

  §3.4 requires an adopter to persist the `:mechanical` row a rule-3 match
  implies, so the *next* base merge resolves at rule 1 instead of
  re-fingerprinting. That is a P4 obligation, not a P3 one: in shadow mode the
  row would be coverage that no guard reads, written on the strength of a
  predicate that has not yet been proven. So `observe/1` discards it, and the
  `:arbiter, :coverage_shadow_record_mechanical` flag (default `false`) exists
  only so P4 can turn the write on ahead of the read flip if the rollout wants
  the rows warm.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Events
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Reviews.CoverageShadow.Tally

  @topic "coverage_shadow"

  # Deduped rows only, under a 7-day retention window — a full read is cheap
  # and this is an operator affordance, not a hot path. The cap is belt and
  # braces against a pathological install.
  @count_limit 10_000

  @typedoc """
  The three-valued answer both predicates are normalised to before they are
  compared. Only the *class* is compared; the second element is detail, logged
  but never diffed — the old guard's `expected_sha` and `decide/3`'s reason are
  not the same kind of value and a textual mismatch between them is not a
  disagreement about whether to merge.
  """
  @type answer :: {:covered, term()} | {:unknown, term()} | {:uncovered, term()}

  @typedoc """
  One shadow observation.

    * `:site` — `:watchdog` or `:merge_queue`.
    * `:old` — the existing guard's answer, normalised to `t:answer/0` by the
      call site. This is the answer that is acted on.
    * `:ctx` — `Coverage.ctx/0`, or a 0-arity function returning one. The
      function form is what keeps a forge lookup off the guard path until the
      shadow actually needs it, and inside this module's rescue when it runs.
    * `:coverage` — optional pre-loaded rows; omitted, they are read for
      `:mr_ref`.
  """
  @type observation :: %{
          required(:site) => :watchdog | :merge_queue,
          required(:task_id) => String.t() | nil,
          required(:mr_ref) => String.t() | nil,
          required(:head) => String.t() | nil,
          required(:old) => answer(),
          optional(:workspace_id) => String.t() | nil,
          optional(:ctx) => Coverage.ctx() | (-> Coverage.ctx()),
          optional(:coverage) => [Entry.t()]
        }

  @doc """
  Evaluate `Coverage.decide/3` alongside the guard's own answer and record
  whether they agree.

  Always returns `:ok`. Every failure mode — an unreadable coverage table, a
  `ctx` lookup that raises, a malformed observation, a tally that is not
  running — is rescued, counted as an error and logged at `:warning`, because
  the caller has already made its decision and this function's only contract
  is not to disturb it.
  """
  @spec observe(observation() | keyword()) :: :ok
  def observe(observation) do
    obs = Map.new(observation)
    old = normalise(Map.get(obs, :old))
    head = Map.get(obs, :head)
    mr_ref = Map.get(obs, :mr_ref)

    coverage = Map.get_lazy(obs, :coverage, fn -> Coverage.for_mr(mr_ref) end)
    ctx = resolve_ctx(Map.get(obs, :ctx))

    {new, mechanical} = Coverage.decide_with_record(coverage, head, ctx)

    maybe_record_mechanical(mechanical)
    record_outcome(obs, old, new)
  rescue
    error -> note_error(observation, Exception.message(error))
  catch
    kind, reason -> note_error(observation, "#{kind}: #{inspect(reason)}")
  end

  @doc """
  The durable disagreement count — the number of distinct `{site, mr_ref,
  head, old, new}` observations on which the two predicates disagreed, over
  the `Arbiter.Events.Retention` window.

  Zero is the result P4 is gated on. Never raises: an unreadable events table
  answers `0` rather than taking down the caller.
  """
  @spec disagreement_count() :: non_neg_integer()
  def disagreement_count, do: Map.get(durable_counts(), "disagree", 0)

  @doc """
  Everything a coordinator needs to answer "may P4 flip?" in one map: the
  durable per-result counts and the since-boot `Tally` snapshot.

  Intended to be read from `iex -S mix` / `mix run --no-start` against the
  install's database.
  """
  @spec report() :: %{durable: %{optional(String.t()) => non_neg_integer()}, since_boot: map()}
  def report, do: %{durable: durable_counts(), since_boot: Tally.snapshot()}

  @doc "The PubSub/event topic the durable counter is written on."
  @spec topic() :: String.t()
  def topic, do: @topic

  # --- internals -----------------------------------------------------------

  defp durable_counts do
    Events.Record
    |> Ash.Query.filter(topic == @topic)
    |> Ash.Query.limit(@count_limit)
    |> Ash.read!()
    |> Enum.frequencies_by(&(Map.get(&1.payload || %{}, "result") || "unknown"))
  rescue
    _ -> %{}
  end

  defp normalise({class, _detail} = answer) when class in [:covered, :unknown, :uncovered],
    do: answer

  defp normalise(other), do: raise(ArgumentError, "unrecognised guard answer #{inspect(other)}")

  defp resolve_ctx(fun) when is_function(fun, 0), do: Map.new(fun.() || %{})
  defp resolve_ctx(ctx), do: Map.new(ctx || %{})

  # §3.4 says the adopter persists the row a rule-3 match implies. P3 is not
  # that adopter — see the moduledoc.
  defp maybe_record_mechanical(nil), do: :ok

  defp maybe_record_mechanical(attrs) do
    if Application.get_env(:arbiter, :coverage_shadow_record_mechanical, false) do
      Coverage.record(attrs)
    end

    :ok
  end

  defp record_outcome(obs, {old_class, old_detail}, {new_class, new_detail}) do
    site = Map.get(obs, :site)
    Tally.bump(:evaluations)
    Tally.bump({:site, site})

    transition = "#{old_class}->#{new_class}"

    if old_class == new_class do
      Tally.bump(:agreements)

      once(obs, transition, fn ->
        persist(obs, "agree", old_class, old_detail, new_class, new_detail)
      end)
    else
      Tally.bump(:disagreements)
      Tally.bump({:transition, transition})

      once(obs, transition, fn ->
        Logger.warning(
          "Reviews.CoverageShadow: DISAGREEMENT site=#{site} task=#{Map.get(obs, :task_id)} " <>
            "mr=#{Map.get(obs, :mr_ref)} head=#{Map.get(obs, :head)} " <>
            "old=#{old_class} old_detail=#{short(old_detail)} " <>
            "new=#{new_class} new_reason=#{short(new_detail)} — shadow only, the existing " <>
            "last_reviewed_sha guard's answer (#{old_class}) is the one acted on"
        )

        persist(obs, "disagree", old_class, old_detail, new_class, new_detail)
      end)
    end

    :ok
  end

  # One report per distinct observation, not one per poll: the MergeQueue
  # re-attempts a refused merge every tick, indefinitely (§2.3's M3), and a
  # per-tick log line and events row would bury the very signal this phase
  # exists to read.
  defp once(obs, transition, fun) do
    key = {Map.get(obs, :site), Map.get(obs, :mr_ref), Map.get(obs, :head), transition}

    if Tally.first_time?(key), do: fun.()

    :ok
  end

  defp persist(obs, result, old_class, old_detail, new_class, new_detail) do
    Events.broadcast(Map.get(obs, :workspace_id), @topic, %{
      result: result,
      site: to_string(Map.get(obs, :site)),
      task_id: Map.get(obs, :task_id),
      mr_ref: Map.get(obs, :mr_ref),
      head: Map.get(obs, :head),
      old: to_string(old_class),
      old_detail: short(old_detail),
      new: to_string(new_class),
      new_reason: short(new_detail)
    })
  end

  defp note_error(observation, message) do
    Tally.bump(:errors)

    Logger.warning(
      "Reviews.CoverageShadow: shadow evaluation failed for #{describe(observation)}: " <>
        "#{message}; the merge guard's own answer is unaffected"
    )

    :ok
  end

  defp describe(observation) when is_map(observation) do
    "site=#{Map.get(observation, :site)} task=#{Map.get(observation, :task_id)} " <>
      "mr=#{Map.get(observation, :mr_ref)} head=#{Map.get(observation, :head)}"
  end

  defp describe(observation), do: "observation=#{short(observation)}"

  # One log line, always. `inspect/2` with a byte cap keeps a pathological
  # reason term from turning a structured line into a paragraph.
  defp short(value) when is_binary(value), do: value
  defp short(value) when is_atom(value), do: to_string(value)

  defp short(value) do
    value
    |> inspect(limit: 5, printable_limit: 120)
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 200)
  end
end
