defmodule Arbiter.Reviews.Coverage do
  @moduledoc """
  P0 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.1/§3.3.

  `record/1` is the **only** writer of `Arbiter.Reviews.Coverage.Entry`
  rows. It is idempotent on `{mr_ref, head_sha, kind}` — a second identical
  call returns the existing row rather than inserting a duplicate, so every
  call site in §3.3 can call it unconditionally without first checking
  whether coverage already exists.

  `decide/3` (§3.2, P2) is the reader: the six-rule
  `covered | uncovered | unknown` predicate both merge paths will collapse
  to. It is a **pure function** — every git/forge fact it needs arrives
  through `ctx` — and as of P2 it has no call site outside its tests.
  Watchdog and MergeQueue adopt it in P3 (shadow) and P4 (flip).
  """

  require Ash.Query

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage.Entry

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

  @typedoc """
  Everything `decide/3` needs to know about the world, injected.

    * `:local_head_sha` — the head *we* last pushed, for rule 2. `nil` when
      we have not pushed (or do not know), which makes rule 2 unreachable.
    * `:base_ref` — what the net diff is taken against. Missing or blank
      resolves to `{:unknown, :no_base_ref}` at rule 4.
    * `:ancestor?` — `(ancestor, descendant -> boolean | {:ok, boolean})`.
      Anything else, including a raise, reads as "not proven", never as
      proven: rule 2 needs an ancestry *proof*.
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
          | {:unknown, :forge_lagging | :diff_unavailable | :no_base_ref | :no_head}

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
       lag and must not wait.
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

    cond do
      # Rule 1.
      covered_head?(coverage, head) -> {{:covered, head}, nil}
      # Rule 2.
      forge_lagging?(coverage, head, ctx) -> {{:unknown, :forge_lagging}, nil}
      # Rules 3 and 4.
      true -> decide_on_content(coverage, head, ctx)
    end
  end

  defp covered_head?(coverage, head), do: Enum.any?(coverage, &(&1.head_sha == head))

  # Rule 2. Each conjunct is load-bearing: the local head must itself be
  # covered (otherwise there is nothing to be lagging *behind*), the forge's
  # head must differ from it (otherwise rule 1 already answered), and the
  # forge's head must be an ancestor of ours (otherwise it is not our push
  # arriving late — it is somebody else's commit, or our own later one).
  defp forge_lagging?(coverage, head, ctx) do
    local_head = Map.get(ctx, :local_head_sha)

    is_binary(local_head) and local_head != head and covered_head?(coverage, local_head) and
      ancestor?(ctx, head, local_head)
  end

  defp ancestor?(ctx, ancestor, descendant) do
    case Map.get(ctx, :ancestor?) do
      fun when is_function(fun, 2) ->
        case safely(fn -> fun.(ancestor, descendant) end) do
          {:ok, true} -> true
          {:ok, {:ok, true}} -> true
          _ -> false
        end

      _ ->
        false
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
end
