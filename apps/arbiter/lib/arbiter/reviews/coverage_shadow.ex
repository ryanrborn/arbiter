defmodule Arbiter.Reviews.CoverageShadow do
  @moduledoc """
  P3 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.4/§6.3:
  **shadow mode**.

  `Arbiter.Worker.Watchdog` and `Arbiter.Workflows.MergeQueue` evaluate **both**
  predicates on every guarded-merge decision — the `issues.last_reviewed_sha`
  guard through `Arbiter.Mergers.ReviewedSha`, and
  `Arbiter.Reviews.Coverage.decide/3` — and hand both answers to `observe/1`,
  which records whether they agree. Nothing in this module can change a merge
  decision: `observe/1` returns `:ok` for every input it is ever given,
  including ones whose `ctx` lookups raise.

  Which of the two is *acted on* is the call site's business, and since P4
  (#1736) it is a workspace flag: `merge.coverage_enabled` off (the default)
  is P3's arrangement — the old guard decides, the coverage predicate shadows
  it — and on is the flip, where `decide/3` decides and the old guard shadows.
  `:authoritative` on the observation is how the log line and the durable row
  say which way round it was.

  That is the whole point of the phase. Flipping on the strength of unit tests
  alone is exactly the move that produced chain A — four guards in nine days,
  each correct in isolation. So shadow mode buys the evidence first: run both
  predicates against real production traffic and count the disagreements.
  `preflip_gate/0` is that count, with §6.3's threshold and §4.5's one
  documented exception applied.

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
  the three-dot compare `ctx.fetch_diff` performs — and, since P4, one more on
  any decision that reaches rule 2 with a covered local head (the ancestry
  probe). Rules 0 and 1 answer without either, so the healthy post-P1 path (a
  `:reviewed` row exists for the head the forge reports) adds no forge traffic
  at all. The paths that do pay
  are the ones where the head already differs from the stamp, which in the
  Watchdog already fetched two diffs of its own (`base_merge_only?/3`); the
  MergeQueue's stale-SHA retry (§2.3's M3, unbounded by design until P6) is
  the one place this is a genuinely new per-tick call. Both adapters route
  through `Arbiter.GitHub.Limiter`, and the phase is short-lived by
  construction — P4 replaces the double evaluation with a single one.

  ## Rule-3 `:mechanical` rows are NOT written in shadow mode

  §3.4 requires an adopter to persist the `:mechanical` row a rule-3 match
  implies, so the *next* base merge resolves at rule 1 instead of
  re-fingerprinting. In shadow mode the row would be coverage that no guard
  reads, written on the strength of a predicate that is not being acted on, so
  `observe/1` discards it; the `:arbiter, :coverage_shadow_record_mechanical`
  flag (default `false`) turns the write on for a rollout that wants the rows
  warm ahead of the flip.

  A **flipped** call site is the adopter §3.4 means, and it holds the row
  itself: it computed the decision it is acting on, so it persists the row
  directly (`Coverage.record/1`) rather than through here, and hands
  `observe/1` the answer it already has.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Events
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Reviews.CoverageShadow.Tally

  @topic "coverage_shadow"

  # Deduped rows only, and `Arbiter.Events.Retention` sweeps the topic, so a
  # full read is cheap and this is an operator affordance, not a hot path. The
  # cap is belt and braces against a pathological install; `durable_rows/0`
  # reads newest-first so hitting it keeps the rows that matter, and
  # `preflip_gate/0` refuses to pass at all once it is hit.
  @count_limit 10_000

  # §6.3's "≥20 real merges" (P4 / bd-df3zlo, #1736 AC3).
  @preflip_min_merges 20

  # The ONE disagreement class that does not block the flip, listed observation
  # by observation and never silently dropped: §4.5's post-approval `fix_pass`
  # class, which P7 owns — the old guard merged a commit no review covers (live:
  # #1702, #1723, #1725, #1731, #1735) and `decide/3` refused it.
  #
  # This list is exactly what #1736's AC3 authorises ("zero disagreements other
  # than the documented post-approval fix_pass class") and is deliberately not
  # one entry longer. `unknown->covered` — the W2 grace window, where the old
  # guard is still waiting out "have we seen our own push echoed yet" while the
  # head the PR reports already has a coverage row, so rule 1 answers on the
  # first poll — is the coverage predicate being *right* (§3.2 states that
  # improvement as rule 2's point, and W7's `expected_sha` still pins the merge
  # to that exact head), and there is one live observation of it, bd-2jkrqu /
  # #1707. It is still counted as **blocking** here: widening a stated
  # acceptance criterion is the coordinator's call, not this module's, so the
  # operator sees it in `:blocking` and decides. P5 removes the grace latch that
  # produces the `unknown` half, after which the class stops occurring at all.
  @deferred_transitions %{
    "covered->uncovered" => "post-approval fix_pass (§4.5, P7)"
  }

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
      call site.
    * `:new` — the coverage predicate's answer, when the call site has already
      computed it (P4's flipped path, which acts on it and must not evaluate
      it twice). Omitted, this module computes it from `:ctx`.
    * `:authoritative` — which of the two was acted on: `:old` (P3, and P4
      with `merge.coverage_enabled` off) or `:new` (P4, flag on). Defaults to
      `:old`. It changes no arithmetic — both answers are recorded and compared
      the same way either way — only which one the log line and the event name
      as load-bearing.
    * `:ctx` — `Coverage.ctx/0`, or a 0-arity function returning one. The
      function form is what keeps a forge lookup off the guard path until the
      shadow actually needs it, and inside this module's rescue when it runs.
      Ignored when `:new` is supplied.
    * `:coverage` — optional pre-loaded rows; omitted, they are read for
      `:mr_ref`.
  """
  @type observation :: %{
          required(:site) => :watchdog | :merge_queue,
          required(:task_id) => String.t() | nil,
          required(:mr_ref) => String.t() | nil,
          required(:head) => String.t() | nil,
          required(:old) => answer(),
          optional(:new) => answer(),
          optional(:authoritative) => :old | :new,
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

    {new, mechanical} =
      case Map.get(obs, :new) do
        nil ->
          coverage = Map.get_lazy(obs, :coverage, fn -> Coverage.for_mr(mr_ref) end)
          Coverage.decide_with_record(coverage, head, resolve_ctx(Map.get(obs, :ctx)))

        answer ->
          # The flipped path decided on this answer already; re-deriving it
          # here would double the forge traffic and could even disagree with
          # the decision that was acted on.
          {normalise(answer), nil}
      end

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

  @doc """
  §6.3's rollout gate, as a query rather than a paragraph (P4 / bd-df3zlo,
  #1736 AC3): **may `merge.coverage_enabled` be turned on?**

  Reads the `#{@count_limit}` most recent durable `coverage_shadow` rows —
  newest `seq` first, whatever `Arbiter.Events.Retention` has left on the topic
  — and answers with the numbers the decision rests on:

    * `:merges` — distinct observations where the guard actually merged
      (`old = "covered"`) *while the old guard was still authoritative*. A
      workspace that has already flipped stops producing evidence about the
      flip, so its rows are excluded.
    * `:blocking` — disagreements per `old->new` transition that must be zero.
    * `:deferred` / `:deferred_observations` — the one documented exception
      #1736's AC3 authorises: `covered->uncovered`, §4.5's post-approval
      `fix_pass` class, P7's ticket. Listed observation by observation rather
      than summed, so the operator can confirm each one really is that shape
      before flipping. `deferred_reasons/0` names it. Every other disagreement
      — including the benign `unknown->covered` grace-window class — counts as
      blocking, because relaxing AC3 is the coordinator's call to make on the
      evidence, not this function's to make for them.
    * `:truncated?` — whether the read hit `#{@count_limit}` rows and so may not
      be the whole topic. A gate cannot pass on evidence it knows is partial, so
      this forces `:pass?` false.

  `:pass?` is `merges >= min_merges` (default 20) with `blocking` empty and
  `truncated?` false.

  Run it against the install's database:

      MIX_ENV=prod mix run --no-start -e \
        'IO.inspect(Arbiter.Reviews.CoverageShadow.preflip_gate(), pretty: true)'

  Never raises: an unreadable events table answers "not yet", which is the
  safe direction for a gate.

  The second argument is the row cap, and exists so the truncation refusal can
  be exercised without seeding `#{@count_limit}` rows. Leave it at its default.
  """
  @spec preflip_gate(pos_integer(), pos_integer()) :: %{
          merges: non_neg_integer(),
          agreements: non_neg_integer(),
          blocking: %{optional(String.t()) => non_neg_integer()},
          deferred: %{optional(String.t()) => non_neg_integer()},
          deferred_observations: [map()],
          min_merges: pos_integer(),
          truncated?: boolean(),
          pass?: boolean()
        }
  def preflip_gate(min_merges \\ @preflip_min_merges, limit \\ @count_limit) do
    read = durable_rows(limit)

    # `durable_counts/0` can live with a capped read; a safety gate cannot. The
    # cap drops rows, and a dropped row could be the one blocking disagreement,
    # so a read that hit the cap is evidence this function knows is partial and
    # must refuse on. (The read is newest-first, so the rows it *does* hold are
    # at least the most recent ones, which is what an operator would look at.)
    truncated? = length(read) >= limit
    rows = Enum.filter(read, &shadow_evidence?/1)

    merges = Enum.count(rows, &(payload(&1, "old") == "covered"))
    agreements = Enum.count(rows, &(payload(&1, "result") == "agree"))
    disagreements = Enum.filter(rows, &(payload(&1, "result") == "disagree"))

    {deferred, blocking} = Enum.split_with(disagreements, &deferred_class?/1)

    %{
      merges: merges,
      agreements: agreements,
      blocking: Enum.frequencies_by(blocking, &transition/1),
      deferred: Enum.frequencies_by(deferred, &transition/1),
      deferred_observations: Enum.map(deferred, &observation_summary/1),
      min_merges: min_merges,
      truncated?: truncated?,
      pass?: merges >= min_merges and blocking == [] and not truncated?
    }
  end

  @doc "The PubSub/event topic the durable counter is written on."
  @spec topic() :: String.t()
  def topic, do: @topic

  # --- internals -----------------------------------------------------------

  defp durable_counts,
    do: Enum.frequencies_by(durable_rows(@count_limit), &(payload(&1, "result") || "unknown"))

  # Newest first: `seq` is the resource's autoincrementing primary key, so a
  # capped read keeps the *recent* rows rather than an arbitrary (in practice
  # oldest-first) subset. `preflip_gate/0` additionally refuses to pass when the
  # cap was hit at all — see `truncated?` there.
  defp durable_rows(limit) do
    Events.Record
    |> Ash.Query.filter(topic == @topic)
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  rescue
    _ -> []
  end

  defp payload(record, key), do: Map.get(record.payload || %{}, key)

  # Rows written while the OLD guard was the authoritative one. P3's rows carry
  # no `authoritative` key at all, and they are exactly that.
  defp shadow_evidence?(record), do: payload(record, "authoritative") in [nil, "old"]

  defp transition(record), do: "#{payload(record, "old")}->#{payload(record, "new")}"

  defp deferred_class?(record), do: Map.has_key?(@deferred_transitions, transition(record))

  @doc """
  The disagreement transitions `preflip_gate/0` does not treat as blocking, and
  why each one is on the list.
  """
  @spec deferred_reasons() :: %{optional(String.t()) => String.t()}
  def deferred_reasons, do: @deferred_transitions

  defp observation_summary(record) do
    %{
      site: payload(record, "site"),
      task_id: payload(record, "task_id"),
      mr_ref: payload(record, "mr_ref"),
      head: payload(record, "head"),
      new_reason: payload(record, "new_reason")
    }
  end

  defp normalise({class, _detail} = answer) when class in [:covered, :unknown, :uncovered],
    do: answer

  defp normalise(other), do: raise(ArgumentError, "unrecognised guard answer #{inspect(other)}")

  defp resolve_ctx(fun) when is_function(fun, 0), do: Map.new(fun.() || %{})
  defp resolve_ctx(ctx), do: Map.new(ctx || %{})

  # §3.4 says the adopter persists the row a rule-3 match implies. P3 is not
  # that adopter — see the moduledoc. P4's flipped path is, but it holds the
  # row itself (it computed the decision), so what reaches this function is
  # always a shadow-mode row.
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
            "new=#{new_class} new_reason=#{short(new_detail)} — " <>
            acted_on(obs, old_class, new_class)
        )

        persist(obs, "disagree", old_class, old_detail, new_class, new_detail)
      end)
    end

    :ok
  end

  # The same line in both modes, differing only in which answer it names as
  # load-bearing — the one fact an operator reading a disagreement needs and
  # cannot infer from the two classes.
  defp acted_on(obs, old_class, new_class) do
    case authoritative(obs) do
      :new ->
        "the coverage predicate's answer (#{new_class}) is the one acted on; the " <>
          "last_reviewed_sha guard now shadows it"

      :old ->
        "shadow only, the existing last_reviewed_sha guard's answer (#{old_class}) " <>
          "is the one acted on"
    end
  end

  defp authoritative(obs) do
    case Map.get(obs, :authoritative) do
      :new -> :new
      _ -> :old
    end
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
      # Which predicate decided this merge. The pre-flip gate counts only rows
      # the old guard decided (`"old"`); once a workspace has flipped, its
      # rows are no longer evidence about whether it may flip.
      authoritative: to_string(authoritative(obs)),
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
