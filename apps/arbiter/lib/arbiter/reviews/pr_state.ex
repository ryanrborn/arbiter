defmodule Arbiter.Reviews.PrState do
  @moduledoc """
  Resolution and retry logic for an `ExternalReview` record's `pr_state`
  (bd-3jjk0e).

  Historically pr_state was resolved *only* by the dashboard LiveView, lazily on
  render, with a coarse `open | merged | closed | unknown` vocabulary in which
  `"unknown"` was a dead-end: once written it was never re-polled, so a single
  transient failure froze a row forever. This module is the single source of
  truth for both the resolution and the "should I re-poll this?" decision, shared
  by three callers:

    * the dashboard LiveView (a *reader* that also opportunistically resolves),
    * the review `complete` path (`Arbiter.Reviews.ExternalReview`), and
    * the background poller (`Arbiter.Reviews.PrStatePoller`), which keeps
      pr_state advancing even when no dashboard is open.

  ## State vocabulary

  The persisted `pr_state` string is one of:

    * `"open"`    — live PR, still open (retry: it may still merge/close).
    * `"merged"`  — terminal.
    * `"closed"`  — terminal.
    * `"gone"`    — soft-terminal; the adapter reported 404 on
                    `@not_found_confirm_threshold` consecutive checks. Not
                    re-polled by the normal cadence, but re-opened for one
                    more verification pass once its confirmation (`gone_at`)
                    goes stale (bd-7qzqfs) — a GitHub token can transiently
                    lack read access and 404 (not 403) to avoid leaking a
                    private resource's existence, so a single 404 is never
                    proof of deletion.
    * `"n/a"`     — terminal; there is no forge PR to poll (a `direct`-strategy
                    review, or a blank strategy / ref).
    * `"unknown"` — a *transient* failure (network, 5xx, rate-limit, token/config
                    not resolvable, or an unconfirmed 404). Retryable — the
                    next tick re-resolves it.

  `nil` means "never resolved yet" and is also retryable.
  """

  alias Arbiter.Mergers

  # States that never change once reached — the poller / dashboard stop
  # re-resolving them. "gone" is a *soft* terminal: see needs_refresh?/1.
  @terminal_states ~w(merged closed gone n/a)

  # Consecutive "not_found" signals required before a record is allowed to
  # commit the terminal "gone" state (bd-7qzqfs). GitHub returns a bare 404 —
  # not 403 — when a token transiently lacks read access to a resource (by
  # design, to avoid leaking the existence of private resources), so a single
  # 404 is not proof the PR was deleted.
  @not_found_confirm_threshold 2

  # How long a "gone" confirmation is trusted before the record is re-opened
  # for one more verification pass, so a wrong "gone" is never a permanent
  # dead end.
  @gone_recheck_after_seconds 86_400

  @doc "The set of terminal pr_state strings (never re-polled)."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @doc "True when `state` is a terminal pr_state string."
  @spec terminal?(term()) :: boolean()
  def terminal?(state) when is_binary(state), do: state in @terminal_states
  def terminal?(_), do: false

  @doc """
  Whether a record's `pr_state` should be re-resolved on the next tick.

  Terminal states (`merged`/`closed`/`gone`/`n/a`) are frozen. Everything else
  — an unresolved (`nil`), still-`open`, previously-`unknown`, or in-flight
  (`:running`) record — is retryable, so a row that hit a transient failure and
  landed on `"unknown"` recovers to its real state on a later tick with no manual
  intervention.
  """
  @spec needs_refresh?(map()) :: boolean()
  def needs_refresh?(%{pr_state: "gone"} = record), do: gone_stale?(record)
  def needs_refresh?(%{pr_state: state}) when state in @terminal_states, do: false
  def needs_refresh?(%{pr_state: nil}), do: true
  def needs_refresh?(%{pr_state: "open"}), do: true
  def needs_refresh?(%{pr_state: "unknown"}), do: true
  def needs_refresh?(%{status: :running}), do: true
  def needs_refresh?(_), do: false

  # A "gone" record is re-opened for one more verification pass once its
  # confirmation is older than the recheck TTL — or immediately if it has no
  # `gone_at` at all, which self-heals rows written before this field existed
  # (exactly the bd-7qzqfs scenario: a single stale 404 froze a live PR).
  defp gone_stale?(record) do
    case Map.get(record, :gone_at) do
      %DateTime{} = at ->
        DateTime.diff(DateTime.utc_now(), at, :second) >= @gone_recheck_after_seconds

      _ ->
        true
    end
  end

  @doc """
  Resolve the live PR state for a single review record by calling the
  appropriate merge adapter within the record's workspace config.

  Returns the pr_state string to persist. Never raises — any unexpected error
  falls through to the transient `"unknown"` so the row is retried rather than
  frozen. `workspace` is the `Arbiter.Tasks.Workspace` struct (or a raw
  merger-config map) for the record's workspace, or `nil` when it cannot be
  resolved (treated as transient → `"unknown"`).
  """
  @spec resolve(map(), map() | nil) :: String.t()
  def resolve(record, workspace) do
    strategy = Map.get(record, :strategy)
    mr_ref = Map.get(record, :pr_ref)

    cond do
      strategy in [nil, "", "direct"] ->
        "n/a"

      is_nil(mr_ref) or mr_ref == "" ->
        "n/a"

      true ->
        adapter = Mergers.for_strategy(strategy_atom(strategy))

        adapter
        |> call_adapter_get(workspace, mr_ref)
        |> classify()
    end
  rescue
    _ -> "unknown"
  end

  @doc """
  Resolve and persist a record's pr_state via the `:update_pr_state` action.

  This is the single *writer* used by both the background poller and the
  review-complete path. Best-effort: returns `{:ok, record}` on success and
  `:error` on any failure (never raises).

  Owns the not-found confirmation logic (bd-7qzqfs): `resolve/2` only ever
  reports the raw per-call signal, so it's this function — the one with
  access to the record's persisted `not_found_count` — that decides whether a
  `"not_found"` signal is committed as terminal `"gone"` or held at retryable
  `"unknown"` pending another confirmation. Any other outcome resets the
  counter, so an intermittent 404 streak doesn't carry over into an unrelated
  future failure.
  """
  @spec resolve_and_persist(Ash.Resource.record(), map() | nil) ::
          {:ok, Ash.Resource.record()} | :error
  def resolve_and_persist(record, workspace) do
    candidate = resolve(record, workspace)
    attrs = reconcile(record, candidate)

    case Ash.update(record, attrs, action: :update_pr_state) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp reconcile(record, "not_found") do
    count = Map.get(record, :not_found_count, 0) + 1

    if count >= @not_found_confirm_threshold do
      %{pr_state: "gone", not_found_count: count, gone_at: DateTime.utc_now()}
    else
      %{pr_state: "unknown", not_found_count: count}
    end
  end

  defp reconcile(_record, candidate), do: %{pr_state: candidate, not_found_count: 0}

  @doc """
  Map an adapter `get/1` result onto a raw pr_state signal.

  Separated from `resolve/2` so the outcome mapping is unit-testable without the
  HTTP plumbing:

    * `{:ok, %{status: :open | :merged | :closed}}` → the matching live state.
    * a hard 404 / not-found error → `"not_found"`, an *intermediate* signal.
      This is never persisted directly — GitHub returns a bare 404 (not 403)
      when a token transiently lacks read access, so a single 404 is not
      proof of deletion. `resolve_and_persist/2` requires several consecutive
      `"not_found"` signals before committing terminal `"gone"` (bd-7qzqfs).
    * anything else (network, 5xx, rate-limit, config) → transient `"unknown"`.
  """
  @spec classify(term()) :: String.t()
  def classify({:ok, %{status: :open}}), do: "open"
  def classify({:ok, %{status: :merged}}), do: "merged"
  def classify({:ok, %{status: :closed}}), do: "closed"
  # Both adapters surface a deleted PR/repo as an %Error{} with kind :not_found
  # (status 404). Match structurally so we don't couple to either Error struct.
  def classify({:error, %{kind: :not_found}}), do: "not_found"
  def classify({:error, %{status: 404}}), do: "not_found"
  def classify(_), do: "unknown"

  # Only github/gitlab reviews reach here (direct/blank short-circuit to "n/a"
  # in resolve/2). `to_existing_atom` avoids atom exhaustion from a stray value;
  # an unexpected strategy raises and is rescued by resolve/2 → "unknown".
  defp strategy_atom(strategy) when is_binary(strategy), do: String.to_existing_atom(strategy)

  # Call adapter.get/1 with the per-process config set up for the workspace. A
  # nil workspace means config couldn't be resolved — a transient condition, so
  # return an error that classify/1 maps to "unknown" (retry), not a terminal.
  defp call_adapter_get(Mergers.Github, workspace, mr_ref) when not is_nil(workspace) do
    Mergers.Github.with_workspace(workspace, fn -> Mergers.Github.get(mr_ref) end)
  end

  defp call_adapter_get(Mergers.Gitlab, workspace, mr_ref) when not is_nil(workspace) do
    Mergers.Gitlab.with_workspace(workspace, fn -> Mergers.Gitlab.get(mr_ref) end)
  end

  defp call_adapter_get(_adapter, _workspace, _mr_ref), do: {:error, :unsupported}
end
