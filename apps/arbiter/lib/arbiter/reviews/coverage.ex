defmodule Arbiter.Reviews.Coverage do
  @moduledoc """
  P0 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.1/§3.3.

  `record/1` is the **only** writer of `Arbiter.Reviews.Coverage.Entry`
  rows. It is idempotent on `{mr_ref, head_sha, kind}` — a second identical
  call returns the existing row rather than inserting a duplicate, so every
  call site in §3.3 can call it unconditionally without first checking
  whether coverage already exists.

  P1 (#1648) wires the three **review** sites of §3.3's stamping table to
  `record/1` — `Arbiter.Worker.ReviewGate`'s clean approve,
  `Arbiter.Workflows.ReviewPatrol`'s post-review and
  `Arbiter.Reviews.ExternalReview`'s baseline.

  `decide/3` (§3.2, P2) is the reader: the six-rule
  `covered | uncovered | unknown` predicate both merge paths will collapse
  to. It is a **pure function** — every git/forge fact it needs arrives
  through `ctx`.

  P3 (#1649) gave it its first call site, `Arbiter.Reviews.CoverageShadow`,
  which both merge paths call *alongside* their existing guard and which acts
  on nothing: it counts and logs whether the two predicates agree.

  P4 (#1736) flips the read path behind the workspace flag
  `merge.coverage_enabled` (`Arbiter.Tasks.Workspace.coverage_enabled?/1`).
  With the flag **off** — the default, and where every workspace starts —
  `issues.last_reviewed_sha` is still the authoritative input to every merge
  decision and this predicate only shadows it. With the flag **on**,
  `Arbiter.Worker.Watchdog` and `Arbiter.Workflows.MergeQueue` act on
  `decide/3`'s answer and the old guard shadows *it*, still logging every
  disagreement. The flag is only turned on for a workspace whose shadow
  evidence passes `Arbiter.Reviews.CoverageShadow.preflip_gate/0`.
  """

  require Ash.Query

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.Issue

  @type attrs :: %{
          required(:task_id) => String.t(),
          required(:mr_ref) => String.t(),
          required(:head_sha) => String.t(),
          required(:base_ref) => String.t(),
          required(:net_diff_id) => String.t(),
          required(:kind) => :reviewed | :mechanical | :operator,
          required(:source) =>
            :review_gate | :review_patrol | :external_review | :watchdog | :cli,
          optional(:round) => integer() | nil,
          optional(:derived_from) => String.t() | nil,
          optional(:covered_at) => DateTime.t()
        }

  @doc """
  Record a coverage entry, or return the existing one if `{mr_ref, head_sha,
  kind}` was already recorded.

  A `:mechanical` row requires `derived_from`; any other kind must leave it
  nil. `head_sha` must be 40 hex characters. Both are rejected by the
  resource's create action and surfaced here as `{:error, _}`.
  """
  @spec record(attrs()) :: {:ok, Entry.t()} | {:error, term()}
  def record(attrs) do
    attrs = Map.new(attrs)

    case fetch_existing(attrs) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        Entry
        |> Ash.Changeset.for_create(:record, attrs)
        |> Ash.create()
        |> case do
          {:ok, entry} -> {:ok, entry}
          {:error, error} -> retry_on_conflict(error, attrs)
        end
    end
  end

  @doc """
  Every coverage row recorded for one MR, oldest first.

  The read scope `decide/3` is meant to be handed: §3.2's rules are all
  statements about *this PR's* coverage set, and `mr_ref` is the only handle
  every writer in §3.3 shares (`task_id` is the authoring task, which a
  ReviewPatrol row about an external PR does not have).

  Raises on a read failure — the shadow/guard call sites wrap it, and a caller
  that wants "no coverage" on a DB error would be answering `:uncovered` to a
  question it could not read, which is exactly RC2's mistake.
  """
  @spec for_mr(String.t() | nil) :: [Entry.t()]
  def for_mr(mr_ref) when is_binary(mr_ref) and mr_ref != "" do
    Entry
    |> Ash.Query.filter(mr_ref == ^mr_ref)
    |> Ash.Query.sort(covered_at: :asc)
    |> Ash.read!()
  end

  def for_mr(_mr_ref), do: []

  @typedoc """
  Everything `decide/3` needs to know about the world, injected.

    * `:local_head_sha` — the head *we* last pushed, for rule 2. `nil` when
      we have not pushed (or do not know), which makes rule 2 unreachable.
    * `:base_ref` — what the net diff is taken against. Missing or blank
      resolves to `{:unknown, :no_base_ref}` at rule 4.
    * `:ancestor?` — `(ancestor, descendant -> boolean | {:ok, boolean})`.
      A `true` is the only thing that proves rule 2's lag. Anything that is
      neither a `true` nor a `false` — an `{:error, _}`, a raise, a timeout, a
      shape we do not recognise — is a probe that was **asked and could not
      answer**, and resolves to `{:unknown, :ancestry_unavailable}` rather
      than falling through to the content rules (P4/#1736 AC4: a probe failure
      yields `unknown`, never `covered`). Omitting the key entirely is
      different: that caller has declared it cannot ask, so rule 2 is simply
      unreachable and rules 3-6 decide.
    * `:fetch_diff` — `(base_ref, head -> {:ok, diff} | diff | {:error, _})`,
      the three-dot compare `NetDiff` fingerprints. Absent, failing or
      unfingerprintable resolves to `{:unknown, :diff_unavailable}`.
    * `:source` — stamped on the `:mechanical` row rule 3 hands back.
      Defaults to `:watchdog`.
  """
  @type ctx :: %{
          optional(:local_head_sha) => String.t() | nil,
          optional(:base_ref) => String.t() | nil,
          optional(:ancestor?) => (String.t(), String.t() -> boolean() | {:ok, boolean()}),
          optional(:fetch_diff) => (String.t(), String.t() ->
                                      {:ok, String.t() | nil}
                                      | String.t()
                                      | nil
                                      | {:error, term()}),
          optional(:source) => atom()
        }

  @typedoc "§3.2's three answer shapes. `{:unknown, _}` is a pause, not a decision."
  @type decision ::
          {:covered, String.t()}
          | {:uncovered, :authored_content | :no_coverage}
          | {:unknown,
             :forge_lagging
             | :ancestry_unavailable
             | :diff_unavailable
             | :no_base_ref
             | :no_head}

  @default_source :watchdog

  @doc """
  Is `head` covered by `coverage`? §3.2's six rules, resolved in order, first
  hit wins.

  `coverage` is the set of entries for the PR under test (the caller decides
  the scope — this function only reads what it is handed). `head` is the sha
  the merge would use, i.e. what the *forge* currently reports.

    0. No `head` at all → `{:unknown, :no_head}`.
    1. `head` is in `coverage` → `{:covered, head}`.
    2. `ctx.local_head_sha` is covered, `head != ctx.local_head_sha`, **and**
       `head` is an ancestor of `ctx.local_head_sha` →
       `{:unknown, :forge_lagging}`. The forge is behind our own push.
       Ancestry is the whole safety argument: an unrelated head, or a
       *descendant* of our covered head (a fix-pass commit — §4.5), is not a
       lag and must not wait. A probe that is asked and cannot answer stops
       here too, as `{:unknown, :ancestry_unavailable}` — with the lag
       question open, the content rules below would be answering a different
       question than the one that was asked.
    3. `NetDiff.fingerprint(base...head)` is in `coverage` → `{:covered, head}`.
       The head carries content that was already reviewed under a different
       sha: a base merge, a rebase-forward, an identical force-push (§4.2).
    4. No usable `base_ref`, or the diff could not be fetched or fingerprinted
       → `{:unknown, :no_base_ref}` / `{:unknown, :diff_unavailable}`. A
       transient forge error must not buy a re-review.
    5. `coverage` is empty → `{:uncovered, :no_coverage}`.
    6. Otherwise → `{:uncovered, :authored_content}`.

  Rules 4 and 5 are in the order the design states them: with an unfetchable
  diff we do not know whether rule 3 would have hit, so the answer is a pause
  even when the coverage set is empty.

  Nothing here writes. See `decide_with_record/3` for the `:mechanical` row a
  rule-3 match produces.
  """
  @spec decide([Entry.t()], String.t() | nil, ctx()) :: decision()
  def decide(coverage, head, ctx) do
    {decision, _record} = decide_with_record(coverage, head, ctx)
    decision
  end

  @doc """
  `decide/3`, plus the coverage row the decision implies.

  Only a rule-3 match implies one: the `:mechanical` row for `head`, naming
  the matched entry as `derived_from`. It is *returned, not written* — this
  function is pure, and the caller (P3/P4's merge paths) decides whether to
  persist it via `record/1`, which accepts the map as-is. Every other rule
  returns `nil`.
  """
  @spec decide_with_record([Entry.t()], String.t() | nil, ctx()) :: {decision(), attrs() | nil}
  def decide_with_record(_coverage, nil, _ctx), do: {{:unknown, :no_head}, nil}

  def decide_with_record(coverage, head, ctx) when is_binary(head) do
    coverage = List.wrap(coverage)
    ctx = Map.new(ctx || %{})

    if covered_head?(coverage, head) do
      # Rule 1.
      {{:covered, head}, nil}
    else
      case forge_lag(coverage, head, ctx) do
        # Rule 2.
        :lagging -> {{:unknown, :forge_lagging}, nil}
        :unavailable -> {{:unknown, :ancestry_unavailable}, nil}
        # Rules 3 to 6.
        :not_lagging -> decide_on_content(coverage, head, ctx)
      end
    end
  end

  defp covered_head?(coverage, head), do: Enum.any?(coverage, &(&1.head_sha == head))

  # Rule 2. Each conjunct is load-bearing: the local head must itself be
  # covered (otherwise there is nothing to be lagging *behind*), the forge's
  # head must differ from it (otherwise rule 1 already answered), and the
  # forge's head must be an ancestor of ours (otherwise it is not our push
  # arriving late — it is somebody else's commit, or our own later one).
  #
  # Three-valued, because "the probe said no" and "the probe could not say"
  # are different facts about the same head and only the first one may fall
  # through to the content rules.
  @spec forge_lag([Entry.t()], String.t(), map()) :: :lagging | :not_lagging | :unavailable
  defp forge_lag(coverage, head, ctx) do
    local_head = Map.get(ctx, :local_head_sha)

    if is_binary(local_head) and local_head != head and covered_head?(coverage, local_head) do
      ancestry(ctx, head, local_head)
    else
      :not_lagging
    end
  end

  # A `true` proves the lag; a `false` disproves it; everything else — an
  # `{:error, _}` from a forge probe, a raise, a shape we do not recognise — is
  # a question that went unanswered, which is neither. No probe at all is the
  # caller saying it cannot ask, which leaves rule 2 unreachable as before.
  defp ancestry(ctx, ancestor, descendant) do
    case Map.get(ctx, :ancestor?) do
      fun when is_function(fun, 2) ->
        case safely(fn -> fun.(ancestor, descendant) end) do
          {:ok, true} -> :lagging
          {:ok, {:ok, true}} -> :lagging
          {:ok, false} -> :not_lagging
          {:ok, {:ok, false}} -> :not_lagging
          _ -> :unavailable
        end

      _ ->
        :not_lagging
    end
  end

  # Rules 3-6.
  defp decide_on_content(coverage, head, ctx) do
    case head_fingerprint(head, ctx) do
      {:ok, fingerprint} ->
        case match_fingerprint(coverage, fingerprint) do
          # Rule 3.
          %Entry{} = matched ->
            {{:covered, head}, mechanical_row(matched, head, fingerprint, ctx)}

          nil ->
            {uncovered(coverage), nil}
        end

      # Rule 4.
      {:error, reason} ->
        {{:unknown, reason}, nil}
    end
  end

  # Rules 5 and 6.
  defp uncovered([]), do: {:uncovered, :no_coverage}
  defp uncovered(_coverage), do: {:uncovered, :authored_content}

  defp head_fingerprint(head, ctx) do
    base_ref = Map.get(ctx, :base_ref)

    with true <- present?(base_ref) || {:error, :no_base_ref},
         {:ok, diff} <- fetch_diff(ctx, base_ref, head),
         fingerprint when is_binary(fingerprint) <- NetDiff.fingerprint(diff) do
      {:ok, fingerprint}
    else
      {:error, :no_base_ref} -> {:error, :no_base_ref}
      # A diff that will not fingerprint is not evidence of anything — see
      # NetDiff.fingerprint/1 on empty diffs.
      _ -> {:error, :diff_unavailable}
    end
  end

  defp fetch_diff(ctx, base_ref, head) do
    case Map.get(ctx, :fetch_diff) do
      fun when is_function(fun, 2) ->
        case safely(fn -> fun.(base_ref, head) end) do
          {:ok, {:ok, diff}} -> {:ok, diff}
          {:ok, diff} when is_binary(diff) -> {:ok, diff}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Oldest first, so `derived_from` chains back to the review round rather
  # than to whichever mechanical row happened to be handed to us first. The
  # key is an integer, not the `DateTime` struct: Erlang term ordering compares
  # maps by key name (`day` before `month` before `year`), which scrambles
  # chronology across month boundaries.
  defp match_fingerprint(coverage, fingerprint) do
    coverage
    |> Enum.filter(&(&1.net_diff_id == fingerprint))
    |> Enum.sort_by(&{covered_at_key(&1.covered_at), &1.id})
    |> List.first()
  end

  defp covered_at_key(%DateTime{} = covered_at), do: DateTime.to_unix(covered_at, :microsecond)
  # An undated row sorts last, so any dated row wins the chain.
  defp covered_at_key(_covered_at), do: :infinity

  defp mechanical_row(%Entry{} = matched, head, fingerprint, ctx) do
    %{
      task_id: matched.task_id,
      mr_ref: matched.mr_ref,
      head_sha: head,
      base_ref: Map.get(ctx, :base_ref),
      net_diff_id: fingerprint,
      kind: :mechanical,
      source: Map.get(ctx, :source) || @default_source,
      derived_from: matched.id
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # An injected probe that blows up answers "we could not tell", which every
  # caller of this helper already treats as the unproven side.
  defp safely(fun) do
    {:ok, fun.()}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp retry_on_conflict(error, attrs) do
    if unique_conflict?(error) do
      case fetch_existing(attrs) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, error}
      end
    else
      {:error, error}
    end
  end

  defp fetch_existing(%{mr_ref: mr_ref, head_sha: head_sha, kind: kind}) do
    Entry
    |> Ash.Query.filter(mr_ref == ^mr_ref and head_sha == ^head_sha and kind == ^kind)
    |> Ash.read_one()
    |> case do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _ -> :error
    end
  end

  defp fetch_existing(_attrs), do: :error

  defp unique_conflict?(%Ash.Error.Invalid{errors: errors}), do: Enum.any?(errors, &conflict?/1)
  defp unique_conflict?(_), do: false

  # The identity's `eager_check?: true` raises this shape on a duplicate
  # {mr_ref, head_sha, kind}; a DB-level unique-index hit under a genuine
  # race surfaces the same struct via the sqlite adapter's constraint match.
  defp conflict?(%Ash.Error.Changes.InvalidChanges{fields: fields}),
    do: :mr_ref in fields and :head_sha in fields and :kind in fields

  defp conflict?(_), do: false

  @doc """
  The **authoring** task id for a coverage row about `mr_ref`, per §3.1
  ("`task_id` — the authoring task (not the reviewer/watchdog task)").

  A review engagement (`review_only: true`) is the *reviewer's* task, not the
  author's, so the reviewing sites cannot use their own id. When the fleet
  authored the PR there is a real task carrying it as `pr_ref`; that id is the
  answer. For a genuinely external PR — the common ReviewPatrol /
  ExternalReview case — no such task exists and `fallback` (the engagement) is
  used, which is the only durable handle we have on that review.

  Never raises: a failed read resolves to `fallback`, so a transient DB blip
  costs a less-precise `task_id`, not a lost coverage row.
  """
  @spec authoring_task_id(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def authoring_task_id(mr_ref, workspace_id, fallback)
      when is_binary(mr_ref) and mr_ref != "" and is_binary(workspace_id) do
    Issue
    |> Ash.Query.filter(
      pr_ref == ^mr_ref and workspace_id == ^workspace_id and review_only != true
    )
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Issue{id: id} | _] -> id
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  def authoring_task_id(_mr_ref, _workspace_id, fallback), do: fallback
end
