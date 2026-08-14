defmodule Arbiter.Loop do
  @moduledoc """
  Ash domain + public API for the **loop-engineering proposal queue** (Stage 2
  of epic #1011, task bd-9j2g3x).

  Stage 1 (`Arbiter.Loop.Analysis`) reads a window of the loop's own telemetry
  and prints suggestions. This domain gives those suggestions a life beyond
  stdout: `record/1` persists one as an `Arbiter.Loop.PendingWrite`, matching it
  against earlier windows by deterministic fingerprint so evidence
  **accumulates** rather than resetting every Monday.

  ## The accumulation mechanic

      window 1: 1 incident   → :hypothesis (below the bar, kept not dropped)
      window 2: +1 incident  → same row reinforced, evidence_count 2
      window 3: +1 incident  → crosses ≥3 incidents / ≥2 tasks
                             → :proposed + one escalation to the coordinator

  Matching is by `fingerprint` — a digest of `{kind, target, category,
  difficulty, repo}` — **never** an LLM comparison. A `:task`-scoped proposal
  bypasses the bar entirely: its blast radius is 1.

  ## Invariants this module enforces

    1. `Arbiter.Loop.Analysis.analyze/1` keeps its zero-writes guarantee.
       Nothing here runs unless the caller opts in with `propose?: true`.
    2. **No auto-apply at any evidence level.** `record/1` never applies;
       promotion only makes a row *applicable*.
    3. **Never delete; archive.** `reject_pending/2` is a state change.
    4. Config changes go through the deep-merge `:patch_config` action.
    5. The apply path calls the same public domain API a human would
       (`Arbiter.Skills.update_skill/2`, `Ash.update(issue, …)`,
       `:patch_config`), so every apply produces a normal PaperTrail version
       attributed to `loop:proposal:<id>` — the queue never writes to those
       tables directly.
  """

  use Ash.Domain

  alias Arbiter.Loop.{PendingWrite, RepoDocPatch}
  alias Arbiter.Mergers
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, RepoConfig, Workspace}
  alias Arbiter.Worker.Worktree

  require Ash.Query
  require Logger

  resources do
    resource PendingWrite
    # AshPaperTrail version rows for PendingWrite.
    resource PendingWrite.Version
  end

  # The documented fleet-wide evidence bar (docs/loop-review.md): ≥ 3 incidents
  # across ≥ 2 distinct tasks. Overridable per workspace under
  # `loop.evidence_bar.{min_incidents,min_distinct_tasks}`.
  @default_evidence_bar %{min_incidents: 3, min_distinct_tasks: 2}

  @live_states [:hypothesis, :proposed]

  # Internal fan-out for every queue state change. See `pubsub_topic/0`.
  @pubsub_topic "loop_proposals"

  @doc "The built-in evidence bar, used when a workspace does not override it."
  @spec default_evidence_bar() :: %{
          min_incidents: pos_integer(),
          min_distinct_tasks: pos_integer()
        }
  def default_evidence_bar, do: @default_evidence_bar

  @doc """
  The effective evidence bar for a workspace (`%Workspace{}`, workspace id, or
  `nil` for the fleet default), read from `loop.evidence_bar` in workspace
  config with `#{inspect(@default_evidence_bar)}` as defaults.
  """
  @spec evidence_bar(Workspace.t() | String.t() | nil) :: %{
          min_incidents: pos_integer(),
          min_distinct_tasks: pos_integer()
        }
  def evidence_bar(nil), do: @default_evidence_bar

  def evidence_bar(%Workspace{config: config}), do: bar_from_config(config)

  def evidence_bar(workspace_id) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> evidence_bar(ws)
      _ -> @default_evidence_bar
    end
  end

  def evidence_bar(_), do: @default_evidence_bar

  defp bar_from_config(config) when is_map(config) do
    block =
      case Map.get(config, "loop") do
        %{} = loop -> Map.get(loop, "evidence_bar")
        _ -> nil
      end

    case block do
      %{} = b ->
        %{
          min_incidents:
            positive_int(Map.get(b, "min_incidents"), @default_evidence_bar.min_incidents),
          min_distinct_tasks:
            positive_int(
              Map.get(b, "min_distinct_tasks"),
              @default_evidence_bar.min_distinct_tasks
            )
        }

      _ ->
        @default_evidence_bar
    end
  end

  defp bar_from_config(_), do: @default_evidence_bar

  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n

  defp positive_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp positive_int(_, default), do: default

  # ---- fingerprint --------------------------------------------------------

  @doc """
  The deterministic cross-window match key for a candidate: a SHA-256 digest of
  the canonicalised `{kind, target, category, difficulty, repo}` tuple.

  Everything else about a candidate (its gist, incident refs, baseline) is
  deliberately **not** an input — those are what accumulate, so including them
  would make every window a fresh fingerprint and defeat the mechanic.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(candidate) when is_map(candidate) do
    [:kind, :target, :category, :difficulty, :repo]
    |> Enum.map(&(candidate |> fetch(&1) |> canonicalise()))
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalise(nil), do: ""
  defp canonicalise(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp canonicalise(v) when is_atom(v), do: Atom.to_string(v)
  defp canonicalise(v) when is_integer(v), do: Integer.to_string(v)
  defp canonicalise(v), do: inspect(v)

  defp fetch(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  # ---- record (insert or reinforce) ---------------------------------------

  @doc """
  Persist a candidate suggestion as a `PendingWrite`, or reinforce the existing
  row with the same fingerprint.

  A candidate is a map with `:kind`, `:gist`, `:scope`, `:category` and the
  other fingerprint inputs (`:target`, `:difficulty`, `:repo`), plus
  `:incident_refs` / `:task_refs` (the evidence), `:target_metric`,
  `:baseline`, `:payload`, `:diff`, `:origin` and `:workspace_id`.

  Insert path: the row lands `:proposed` when it clears the workspace's
  evidence bar or is `:task`-scoped, otherwise `:hypothesis`.

  Reinforce path: `incident_refs` / `task_refs` are **unioned** (so re-running
  the pass over the same window is idempotent), the counts are recomputed from
  the union, and a `:hypothesis` that now clears the bar is promoted. A
  `:proposed` row stays proposed; a `:rejected` row keeps accumulating evidence
  but is deliberately **not** re-proposed (invariant: a soft rejection is not
  re-litigated from scratch).

  Promotion to `:proposed` posts exactly one escalation to the coordinator
  mailbox, guarded by `escalated_at`.
  """
  @spec record(map(), keyword()) :: {:ok, PendingWrite.t()} | {:error, term()}
  def record(candidate, opts \\ []) when is_map(candidate) do
    fp = fingerprint(candidate)
    bar = Keyword.get(opts, :evidence_bar) || evidence_bar(fetch(candidate, :workspace_id))
    actor = Keyword.get(opts, :actor, "loop")

    case match_existing(fp) do
      nil -> insert(candidate, fp, bar, actor)
      existing -> reinforce(existing, candidate, bar, actor)
    end
  end

  @doc """
  Hand-author a `:repo_doc_patch` candidate and persist it through `record/2`
  (bd-1cusio).

  The Stage 1 pass cannot attribute a reviewer-finding category to one repo
  (`Arbiter.Loop.Proposals` leaves `repo: nil` on every `:claude_md`-destined
  finding, and the apply path refuses a row with no repo), so this is
  currently the only production entry point onto rung 2 of the destination
  ladder: an operator who has read a repo-specific lesson names the repo and
  the lesson text directly, rather than waiting on that attribution work.

  `attrs`:

    * `:repo` (required) — the `repo_paths` key in the target
      workspace's config.
    * `:lesson` (required) — the entry text. Must be a single line with no
      `arbiter:begin`/`arbiter:end` marker (`RepoDocPatch.upsert/4` rejects
      it otherwise); the apply path surfaces that as an `:invalid` error.
    * `:category` (optional) — defaults to `"repo doc: " <> lesson` elided.
    * `:workspace_id` (optional) — stamped on the row; the apply path falls
      back to it when the payload names no workspace of its own.
    * `:actor` (optional, default `"loop"`).

  `:task`-scoped like a difficulty override: a hand-authored lesson is a
  deliberate single proposal, not an aggregate that needs to clear the
  evidence bar, so it lands `:proposed` immediately.
  """
  @spec propose_repo_doc_patch(map()) :: {:ok, PendingWrite.t()} | {:error, term()}
  def propose_repo_doc_patch(attrs) when is_map(attrs) do
    with {:ok, repo} <- required_string(attrs, :repo),
         {:ok, lesson} <- required_string(attrs, :lesson) do
      workspace_id = fetch(attrs, :workspace_id)
      category = fetch(attrs, :category) || "repo doc: #{elide_gist(lesson)}"

      candidate = %{
        kind: :repo_doc_patch,
        scope: :task,
        category: category,
        target: nil,
        difficulty: nil,
        repo: repo,
        gist: elide_gist(lesson),
        incident_refs: [],
        task_refs: [],
        payload: %{"lesson" => lesson},
        diff: nil,
        origin: "loop.propose_repo_doc_patch",
        workspace_id: workspace_id
      }

      record(candidate, actor: fetch(attrs, :actor) || "loop")
    end
  end

  defp required_string(attrs, key) do
    case fetch(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:invalid, "`#{key}` is required"}}
    end
  end

  @gist_limit 160
  defp elide_gist(text) when byte_size(text) <= @gist_limit, do: text
  defp elide_gist(text), do: String.slice(text, 0, @gist_limit - 1) <> "…"

  # Match precedence: a live row (:proposed before :hypothesis) first, then a
  # soft-rejected one. `:applied` / `:superseded` rows are deliberately not
  # matched — a recurrence after an apply is a *new* hypothesis, which is the
  # signal the re-grading pass reads as "the fix did not land".
  defp match_existing(fingerprint) do
    PendingWrite
    |> Ash.Query.filter(fingerprint == ^fingerprint)
    |> Ash.Query.filter(state in [:proposed, :hypothesis, :rejected])
    |> Ash.read!()
    |> Enum.min_by(&state_rank(&1.state), fn -> nil end)
  end

  defp state_rank(:proposed), do: 0
  defp state_rank(:hypothesis), do: 1
  defp state_rank(:rejected), do: 2
  defp state_rank(_), do: 3

  defp insert(candidate, fingerprint, bar, actor) do
    incident_refs = refs(candidate, :incident_refs)
    task_refs = refs(candidate, :task_refs)
    scope = fetch(candidate, :scope) || :fleet

    state =
      if clears_bar?(scope, length(incident_refs), length(task_refs), bar),
        do: :proposed,
        else: :hypothesis

    attrs = %{
      kind: fetch(candidate, :kind),
      gist: fetch(candidate, :gist),
      diff: fetch(candidate, :diff),
      payload: fetch(candidate, :payload) || %{},
      target_metric: fetch(candidate, :target_metric),
      baseline: fetch(candidate, :baseline),
      context_cost_tokens:
        context_cost_tokens(
          fetch(candidate, :gist),
          scope,
          fetch(candidate, :kind),
          fetch(candidate, :payload)
        ),
      evidence_count: length(incident_refs),
      distinct_tasks: length(task_refs),
      incident_refs: incident_refs,
      task_refs: task_refs,
      scope: scope,
      state: state,
      fingerprint: fingerprint,
      category: fetch(candidate, :category),
      target: fetch(candidate, :target),
      difficulty: fetch(candidate, :difficulty),
      repo: fetch(candidate, :repo),
      origin: fetch(candidate, :origin) || "loop.analyze",
      actor: actor,
      workspace_id: fetch(candidate, :workspace_id)
    }

    with {:ok, row} <- Ash.create(PendingWrite, attrs, action: :propose, actor: actor) do
      announce(row, :recorded)
      maybe_escalate(row, actor)
    end
  end

  defp reinforce(existing, candidate, bar, actor) do
    incident_refs = Enum.uniq(existing.incident_refs ++ refs(candidate, :incident_refs))
    task_refs = Enum.uniq(existing.task_refs ++ refs(candidate, :task_refs))

    state =
      case existing.state do
        :hypothesis ->
          if clears_bar?(existing.scope, length(incident_refs), length(task_refs), bar),
            do: :proposed,
            else: :hypothesis

        # A :proposed row stays proposed; a :rejected one stays rejected —
        # accumulating evidence must not silently re-open a decided proposal.
        other ->
          other
      end

    attrs = %{
      incident_refs: incident_refs,
      task_refs: task_refs,
      evidence_count: length(incident_refs),
      distinct_tasks: length(task_refs),
      state: state,
      # The gist/baseline describe the *current* evidence and are still
      # pre-application here (only pre-application states are reinforced), so
      # refreshing them keeps the pre-registered baseline honest.
      gist: fetch(candidate, :gist) || existing.gist,
      baseline: fetch(candidate, :baseline) || existing.baseline,
      target_metric: fetch(candidate, :target_metric) || existing.target_metric,
      # A revised gist changes what would land in every prompt, so the recurring
      # price is re-estimated with it rather than left stale at the first
      # window's figure.
      context_cost_tokens:
        context_cost_tokens(
          fetch(candidate, :gist) || existing.gist,
          existing.scope,
          existing.kind,
          fetch(candidate, :payload) || existing.payload
        ),
      diff: fetch(candidate, :diff) || existing.diff,
      payload: fetch(candidate, :payload) || existing.payload,
      actor: actor
    }

    with {:ok, row} <- Ash.update(existing, attrs, action: :reinforce, actor: actor) do
      announce(row, :reinforced)
      maybe_escalate(row, actor)
    end
  end

  defp refs(candidate, key) do
    case fetch(candidate, key) do
      list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> Enum.uniq()
      _ -> []
    end
  end

  # ---- context cost (Amendment D) -----------------------------------------
  #
  # "A system that learns from itself without growing worker contexts too much
  # with those learnings." Every lesson the loop persists is paid for by every
  # worker that carries it, so each proposal is priced by the *recurring*
  # context it would add to an average dispatch — not by the one-off cost of
  # applying it. Surfaced in `arb loop pending` and the diff view so nobody
  # approves a fleet-wide prompt addition without seeing its standing price.
  #
  # Deliberately a cheap local estimate, not a tokenizer call: this runs inside
  # the analysis pass, which must stay free of network I/O and LLM calls.

  # A repo_doc_patch is never blast-radius-1 even at :task scope: the managed
  # CLAUDE.md section it writes is injected into *every* dispatch in that
  # repo, forever — the opposite of a per-task override. Priced off the
  # lesson text itself (what actually lands in the file), falling back to the
  # gist when the payload has none yet (e.g. mid-analysis candidates).
  defp context_cost_tokens(gist, _scope, :repo_doc_patch, payload) do
    case payload && Map.get(payload, "lesson") do
      lesson when is_binary(lesson) -> estimate_tokens(lesson)
      _ -> context_cost_tokens(gist, :fleet, :other, nil)
    end
  end

  # Blast radius 1. A per-task override is charged once, against the one task
  # that carries it, and never lands in another dispatch's prompt.
  defp context_cost_tokens(_gist, :task, _kind, _payload), do: 0

  # A difficulty override is a routing change: it alters *which* model runs, not
  # what is in the prompt, so it is context-cost-neutral at any scope.
  defp context_cost_tokens(_gist, _scope, :difficulty_override, _payload), do: 0

  # A config change sets a value; it does not add prose to the prompt.
  defp context_cost_tokens(_gist, _scope, :config_set, _payload), do: 0

  # What is left is fleet-wide prose — a skill patch or a new skill — which is
  # carried by every dispatch that materializes it, forever.
  defp context_cost_tokens(gist, _scope, _kind, _payload) when is_binary(gist),
    do: estimate_tokens(gist)

  defp context_cost_tokens(_gist, _scope, _kind, _payload), do: 0

  # Tokens, not bytes (Amendment D item 4). Skill clauses skew toward paths,
  # flags and code fragments, which tokenize far worse than prose, so a byte
  # count under-reads exactly the content most likely to be added. ~4 chars per
  # token is the standard rule of thumb for English; the ceiling keeps a short
  # clause from rounding down to zero and reading as free.
  defp estimate_tokens(text) do
    text |> String.length() |> Kernel./(4) |> Float.ceil() |> trunc()
  end

  # `:task` scope is blast-radius 1 (a paper-trailed per-task override), so it
  # bypasses the fleet-wide evidence bar by design.
  defp clears_bar?(:task, _incidents, _tasks, _bar), do: true

  defp clears_bar?(_scope, incidents, tasks, bar),
    do: incidents >= bar.min_incidents and tasks >= bar.min_distinct_tasks

  # ---- escalation + events ------------------------------------------------

  # Exactly-once: `escalated_at` is the guard. A row promoted to :proposed (or
  # created there) posts one coordinator escalation; every later reinforcement
  # sees a non-nil `escalated_at` and stays silent.
  #
  # The stamp is only written when the post actually happened. `Message` needs a
  # workspace (`workspace_id` is `allow_nil? false`) and most proposals are
  # fleet-wide with none of their own, so the post can genuinely be skipped —
  # stamping regardless would mark the row escalated forever and silently
  # swallow a fleet-wide proposal nobody was ever told about.
  defp maybe_escalate(%PendingWrite{state: :proposed, escalated_at: nil} = row, actor) do
    posted = post_escalation(row)
    announce(row, :proposed)

    case posted do
      :ok -> stamp_escalated(row, actor)
      :skipped -> {:ok, row}
    end
  end

  defp maybe_escalate(row, _actor), do: {:ok, row}

  defp stamp_escalated(row, actor) do
    case Ash.update(row, %{actor: actor}, action: :mark_escalated, actor: actor) do
      {:ok, stamped} -> {:ok, stamped}
      # The stamp is bookkeeping; never fail an accepted proposal because it did
      # not save. A retry next window is harmless (at worst one extra mail).
      {:error, _} -> {:ok, row}
    end
  end

  defp post_escalation(%PendingWrite{} = row) do
    case notify_workspace_id(row) do
      nil ->
        Logger.debug("Arbiter.Loop escalation skipped: no workspace to post into")
        :skipped

      ws_id ->
        send_escalation(row, ws_id)
    end
  end

  defp send_escalation(row, ws_id) do
    case Message.send_mail(%{
           kind: :escalation,
           to_ref: Message.coordinator_ref(),
           from_ref: "loop",
           workspace_id: ws_id,
           subject: "loop proposal ready for review: #{row.gist}",
           body: """
           A loop-analysis finding has crossed the evidence bar and is queued as a reviewable proposal.

           Kind:      #{row.kind} (#{row.scope}-scoped)
           Evidence:  #{row.evidence_count} incident(s) across #{row.distinct_tasks} distinct task(s)
           Metric:    #{row.target_metric || "—"} (baseline: #{row.baseline || "—"})

           Nothing has been applied. Review it with:

               arb loop diff #{row.id}
               arb loop apply #{row.id}      # or: arb loop reject #{row.id} --reason "..."
           """
         }) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.debug("Arbiter.Loop escalation failed: #{inspect(reason)}")
        :skipped
    end
  rescue
    e ->
      Logger.debug("Arbiter.Loop escalation swallowed: #{Exception.message(e)}")
      :skipped
  end

  # A fleet-wide proposal has no workspace of its own, but the coordinator
  # mailbox and the `/events` stream are both workspace-keyed. `arb loop analyze
  # --propose` without `--workspace` is the primary path, so falling back to the
  # installation default workspace is what makes the escalation fire at all.
  # `default_workspace_id/0` deliberately errors when the install is ambiguous
  # (several workspaces, none named "default"), and there we stay silent rather
  # than pick one.
  defp notify_workspace_id(%PendingWrite{workspace_id: ws_id}) when is_binary(ws_id),
    do: ws_id

  defp notify_workspace_id(_row) do
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} -> ws_id
      _ -> nil
    end
  end

  @doc """
  PubSub topic the queue publishes every state change on, for in-process
  subscribers (the `/loop` dashboard).

  Distinct from the `/events` `loop_proposal` topic on purpose: `/events` is
  keyed by workspace and can only carry a workspace-scoped row, while most
  proposals are fleet-wide with no workspace at all.
  """
  def pubsub_topic, do: @pubsub_topic

  defp announce(%PendingWrite{} = row, event) do
    payload = %{
      event: event,
      id: row.id,
      kind: row.kind,
      state: row.state,
      scope: row.scope,
      gist: row.gist,
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks
    }

    Phoenix.PubSub.broadcast(Arbiter.PubSub, @pubsub_topic, {:loop_proposal, event, row.id})

    # `Arbiter.Events.broadcast/3` is workspace-keyed and no-ops on a nil id, and
    # a fleet-wide proposal carries no workspace of its own — so it is published
    # onto the installation default workspace's stream, the same fallback the
    # escalation uses. Ambiguous installs resolve to nil and simply don't reach
    # `/events`.
    Arbiter.Events.broadcast(notify_workspace_id(row), "loop_proposal", payload)
  rescue
    e ->
      Logger.debug("Arbiter.Loop announce swallowed: #{Exception.message(e)}")
      :ok
  end

  # ---- reads --------------------------------------------------------------

  @doc """
  List queued proposals, newest first. Options: `:state` (atom or list of
  atoms; defaults to every state), `:workspace_id`, `:kind`, `:limit`.
  """
  @spec list_pending(keyword()) :: [PendingWrite.t()]
  def list_pending(opts \\ []) do
    PendingWrite
    |> Ash.Query.new()
    |> filter_states(Keyword.get(opts, :state))
    |> filter_eq(:workspace_id, Keyword.get(opts, :workspace_id))
    |> filter_eq(:kind, Keyword.get(opts, :kind))
    |> Ash.Query.sort(created_at: :desc)
    |> then(fn q ->
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> Ash.Query.limit(q, n)
        _ -> q
      end
    end)
    |> Ash.read!()
  end

  defp filter_states(query, nil), do: query
  defp filter_states(query, []), do: query

  defp filter_states(query, states) when is_list(states),
    do: Ash.Query.filter(query, state in ^states)

  defp filter_states(query, state), do: filter_states(query, [state])

  defp filter_eq(query, _field, nil), do: query

  defp filter_eq(query, :workspace_id, value),
    do: Ash.Query.filter(query, workspace_id == ^value)

  defp filter_eq(query, :kind, value), do: Ash.Query.filter(query, kind == ^value)

  @doc "Fetch one proposal by id."
  @spec get_pending(String.t()) :: {:ok, PendingWrite.t()} | {:error, :not_found}
  def get_pending(id) when is_binary(id) do
    case Ash.get(PendingWrite, id) do
      {:ok, row} -> {:ok, row}
      _ -> {:error, :not_found}
    end
  end

  @doc "True when the proposal is in a state an operator may apply (`:proposed` only)."
  @spec applicable?(PendingWrite.t()) :: boolean()
  def applicable?(%PendingWrite{state: :proposed}), do: true
  def applicable?(%PendingWrite{}), do: false

  @doc """
  Human-readable explanation of why a proposal is not applicable, naming its
  current evidence count and what is still needed. `nil` when it *is*
  applicable.
  """
  @spec inapplicable_reason(PendingWrite.t()) :: String.t() | nil
  def inapplicable_reason(%PendingWrite{state: :proposed}), do: nil

  def inapplicable_reason(%PendingWrite{state: :hypothesis} = row) do
    bar = evidence_bar(row.workspace_id)

    "still a hypothesis: #{row.evidence_count} incident(s) across " <>
      "#{row.distinct_tasks} distinct task(s); the evidence bar is " <>
      "≥ #{bar.min_incidents} incidents across ≥ #{bar.min_distinct_tasks} distinct tasks " <>
      "(needs #{shortfall(bar.min_incidents, row.evidence_count)} more incident(s) and " <>
      "#{shortfall(bar.min_distinct_tasks, row.distinct_tasks)} more distinct task(s))"
  end

  def inapplicable_reason(%PendingWrite{state: state}),
    do: "state is #{state} — only a :proposed row can be applied"

  # `Ash.Domain` defines its own `max/2` code interface, which shadows
  # `Kernel.max/2` inside this module — hence the explicit helper.
  defp shortfall(required, have) when required > have, do: required - have
  defp shortfall(_required, _have), do: 0

  # ---- apply --------------------------------------------------------------

  @doc """
  Apply a queued proposal. Dispatches on `kind` to the **existing** public
  domain API — never a direct table write — so the change lands as a normal
  PaperTrail version attributed to `loop:proposal:<id>`.

  Refuses anything that is not `:proposed`, naming the current evidence count
  and what is still needed. On success the row moves to `:applied` with
  `applied_at` stamped.
  """
  @spec apply_pending(PendingWrite.t() | String.t(), keyword()) ::
          {:ok, PendingWrite.t()}
          | {:error, :not_found}
          | {:error, {:not_applicable | :unmapped | :invalid, String.t()}}
  def apply_pending(row_or_id, opts \\ [])

  def apply_pending(id, opts) when is_binary(id) do
    with {:ok, row} <- get_pending(id), do: apply_pending(row, opts)
  end

  def apply_pending(%PendingWrite{} = row, opts) do
    operator = Keyword.get(opts, :actor, "operator")

    case inapplicable_reason(row) do
      nil ->
        do_apply(row, operator)

      reason ->
        {:error, {:not_applicable, reason}}
    end
  end

  defp do_apply(row, operator) do
    # The change is attributed to the proposal, not to the loop: reading the
    # target's version history shows exactly which queued proposal moved it.
    attribution = "loop:proposal:#{row.id}"

    case dispatch_apply(row, attribution) do
      :ok ->
        with {:ok, applied} <-
               Ash.update(row, %{state: :applied, actor: operator},
                 action: :mark_applied,
                 actor: operator
               ) do
          announce(applied, :applied)
          {:ok, applied}
        end

      {:error, _} = err ->
        err
    end
  end

  defp dispatch_apply(%PendingWrite{kind: :difficulty_override, payload: payload}, attribution) do
    with {:ok, task_id} <- payload_string(payload, "task_id"),
         {:ok, difficulty} <- payload_integer(payload, "difficulty"),
         {:ok, issue} <- fetch_issue(task_id) do
      # `change_origin` is the Issue-side attribution hook: it lands in the
      # version row's `version_action_inputs`, since Issue has no `actor`
      # column to snapshot the way Skill / Workspace do.
      case Ash.update(issue, %{difficulty: difficulty, change_origin: attribution},
             action: :update,
             actor: attribution
           ) do
        {:ok, _} -> :ok
        {:error, err} -> {:error, {:invalid, ash_message(err)}}
      end
    end
  end

  defp dispatch_apply(%PendingWrite{kind: :skill_patch, payload: payload}, attribution) do
    with {:ok, ref} <- payload_string(payload, "skill", skill_gap_message()),
         {:ok, attrs} <- skill_attrs(payload) do
      case Arbiter.Skills.update_skill(ref, attrs, actor: attribution) do
        {:ok, _} -> :ok
        {:error, :not_found} -> {:error, {:unmapped, "no skill named #{inspect(ref)}"}}
        {:error, err} -> {:error, {:invalid, ash_message(err)}}
      end
    end
  end

  defp dispatch_apply(%PendingWrite{kind: :skill_create, payload: payload}, attribution) do
    with {:ok, name} <- payload_string(payload, "name"),
         {:ok, body} <- payload_string(payload, "body") do
      attrs =
        %{name: name, body: body}
        |> maybe_put(:metadata, Map.get(payload, "metadata"))
        |> maybe_put(:workspace_id, Map.get(payload, "workspace_id"))

      case Arbiter.Skills.create_skill(attrs, actor: attribution) do
        {:ok, _} -> :ok
        {:error, err} -> {:error, {:invalid, ash_message(err)}}
      end
    end
  end

  # Invariant 4: config changes go through the deep-merge `:patch_config`
  # action, never a raw overwrite of `config`.
  defp dispatch_apply(%PendingWrite{kind: :config_set} = row, attribution) do
    payload = row.payload

    with {:ok, ws_id} <- config_workspace(payload, row.workspace_id),
         {:ok, patch} <- payload_map(payload, "patch"),
         {:ok, ws} <- fetch_workspace(ws_id) do
      unset = Map.get(payload, "unset_paths") || []

      case Ash.update(ws, %{patch: patch, unset_paths: unset},
             action: :patch_config,
             actor: attribution
           ) do
        {:ok, _} -> :ok
        {:error, err} -> {:error, {:invalid, ash_message(err)}}
      end
    end
  end

  # Rung 2 of the destination ladder (Amendment D): a repo-scoped lesson lands
  # as a patch to that repo's CLAUDE.md, applied through the normal PR path —
  # not a direct table write, since the target is a file humans also edit.
  # `Worktree.create/3` gives an isolated branch to commit into;
  # `RepoDocPatch.upsert/4` owns the delimited managed section so a human edit
  # and an Arbiter edit never clobber each other; `Mergers.for_workspace/1`
  # opens the PR the same way any other change in that repo would be opened.
  defp dispatch_apply(%PendingWrite{kind: :repo_doc_patch} = row, attribution) do
    payload = row.payload

    with {:ok, repo} <- repo_doc_repo(row),
         {:ok, lesson} <- payload_string(payload, "lesson"),
         {:ok, ws_id} <- config_workspace(payload, row.workspace_id),
         {:ok, ws} <- fetch_workspace(ws_id),
         {:ok, {repo_path, target_branch}} <- resolve_repo_doc_target(ws, repo) do
      apply_repo_doc_patch(ws, repo, repo_path, target_branch, row, lesson, attribution)
    end
  end

  defp repo_doc_repo(%PendingWrite{repo: repo}) when is_binary(repo) and repo != "",
    do: {:ok, repo}

  defp repo_doc_repo(_row) do
    {:error,
     {:unmapped,
      "this proposal names no repo: CLAUDE.md needs a repo-scoped finding to know which " <>
        "repo's file to patch — attribute the finding to a repo before proposing it"}}
  end

  defp resolve_repo_doc_target(%Workspace{config: config}, repo) do
    paths = Map.get(config || %{}, "repo_paths") || %{}

    case RepoConfig.find_entry(paths, repo) do
      nil ->
        {:error,
         {:unmapped, "repo #{inspect(repo)} is not registered in this workspace's repo_paths"}}

      entry ->
        case RepoConfig.repo_path_from_config(entry) do
          nil ->
            {:error, {:unmapped, "repo #{inspect(repo)}'s repo_paths entry has no path"}}

          path ->
            {:ok, {path, RepoConfig.repo_target_from_config(entry) || "main"}}
        end
    end
  end

  defp apply_repo_doc_patch(ws, repo, repo_path, target_branch, row, lesson, attribution) do
    branch = "loop/repo-doc-patch-#{row.id}"

    case Worktree.create(repo_path, branch, target_branch) do
      {:ok, worktree_path} ->
        result =
          write_repo_doc_patch(
            ws,
            repo,
            repo_path,
            target_branch,
            worktree_path,
            branch,
            row,
            lesson,
            attribution
          )

        _ = Worktree.cleanup(worktree_path)
        result

      {:error, reason} ->
        {:error,
         {:invalid, "could not provision a worktree for #{repo_path}: #{inspect(reason)}"}}
    end
  end

  defp write_repo_doc_patch(
         ws,
         repo,
         repo_path,
         target_branch,
         worktree_path,
         branch,
         row,
         lesson,
         attribution
       ) do
    doc_path = repo_doc_path(row.payload)
    file_path = Path.join(worktree_path, doc_path)
    current = repo_doc_read(file_path)
    cap_bytes = repo_doc_cap_bytes(row.payload)

    with {:ok, %{content: new_content, removed: removed}} <-
           RepoDocPatch.upsert(current, row.fingerprint, lesson, cap_bytes: cap_bytes),
         :ok <- File.write(file_path, new_content),
         :ok <-
           repo_doc_commit(
             worktree_path,
             doc_path,
             repo_doc_commit_message(row, removed, attribution)
           ),
         :ok <- Mergers.prepare_with_repo(ws, repo),
         adapter <- Mergers.for_workspace(ws),
         :ok <- repo_doc_maybe_push(adapter, worktree_path),
         {:ok, _mr_ref} <-
           Mergers.open_with_retry(
             adapter,
             branch,
             row.gist,
             repo_doc_pr_description(row, lesson, removed),
             %{repo_path: repo_path, target_branch: target_branch}
           ) do
      :ok
    else
      {:error, {:entry_too_large, cap_bytes}} ->
        {:error,
         {:invalid,
          "this lesson (#{byte_size(lesson)} bytes) alone exceeds the #{cap_bytes}-byte CLAUDE.md section cap"}}

      {:error, :invalid_entry_text} ->
        {:error,
         {:invalid,
          "this lesson must be a single line with no arbiter:begin/end markers " <>
            "(CLAUDE.md entries are rendered one per line)"}}

      {:error, reason} ->
        {:error, {:invalid, inspect(reason)}}
    end
  end

  # bd-1cusio: this write path is scoped to a repo's CLAUDE.md, not arbitrary
  # files — any payload-supplied override is ignored so no proposal can steer
  # `File.write/2` outside the file this feature exists to patch.
  defp repo_doc_path(_payload), do: "CLAUDE.md"

  defp repo_doc_cap_bytes(payload) do
    case Map.get(payload, "cap_bytes") do
      n when is_integer(n) and n > 0 -> n
      _ -> 4_000
    end
  end

  defp repo_doc_read(file_path) do
    case File.read(file_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp repo_doc_commit(worktree_path, doc_path, message) do
    with {_, 0} <- System.cmd("git", ["add", doc_path], cd: worktree_path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", message], cd: worktree_path, stderr_to_stdout: true) do
      :ok
    else
      {output, _status} -> {:error, {:git_commit_failed, output}}
    end
  end

  # `Direct` operates on the canonical repo's own refs (no remote), so pushing
  # would just fail against whatever `origin` the local checkout has — or has
  # none at all. Every remote-backed adapter needs the branch pushed first.
  defp repo_doc_maybe_push(Mergers.Direct, _worktree_path), do: :ok

  defp repo_doc_maybe_push(_adapter, worktree_path) do
    case Worktree.push(worktree_path, set_upstream: true) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_push_failed, reason}}
    end
  end

  defp repo_doc_commit_message(row, [], attribution),
    do: "#{row.gist}\n\nApplied-by: #{attribution}"

  defp repo_doc_commit_message(row, removed, attribution) do
    "#{row.gist}\n\n" <>
      "Evicted (over the CLAUDE.md size cap): #{Enum.join(removed, ", ")}\n\n" <>
      "Applied-by: #{attribution}"
  end

  defp repo_doc_pr_description(row, lesson, removed) do
    base =
      "Repo-scoped lesson from the loop pass (bd-9j2g3x), applied as proposal `#{row.id}`.\n\n#{lesson}"

    case removed do
      [] ->
        base

      _ ->
        base <>
          "\n\n**Evicted to stay under the CLAUDE.md size cap:** #{Enum.join(removed, ", ")}"
    end
  end

  defp skill_gap_message do
    "this proposal names no target skill: the loop does not yet map a finding " <>
      "category to a skill (Stage 3 work), so the skill patch must be authored " <>
      "by hand — reject this row once you have"
  end

  defp skill_attrs(payload) do
    attrs =
      %{}
      |> maybe_put(:body, Map.get(payload, "body"))
      |> maybe_put(:metadata, Map.get(payload, "metadata"))
      |> maybe_put(:activation_mode, Map.get(payload, "activation_mode"))

    if map_size(attrs) == 0 do
      {:error, {:unmapped, "this proposal carries no skill patch content to apply"}}
    else
      {:ok, attrs}
    end
  end

  defp config_workspace(payload, fallback) do
    case Map.get(payload, "workspace_id") || fallback do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, {:unmapped, "this proposal names no workspace to configure"}}
    end
  end

  defp fetch_issue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, issue} -> {:ok, issue}
      _ -> {:error, {:unmapped, "no task #{task_id}"}}
    end
  end

  defp fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> {:ok, ws}
      _ -> {:error, {:unmapped, "no workspace #{ws_id}"}}
    end
  end

  defp payload_string(payload, key, message \\ nil) do
    case Map.get(payload, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:unmapped, message || "payload is missing #{inspect(key)}"}}
    end
  end

  defp payload_integer(payload, key) do
    case Map.get(payload, key) do
      n when is_integer(n) ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:unmapped, "payload #{inspect(key)} is not an integer"}}
        end

      _ ->
        {:error, {:unmapped, "payload is missing #{inspect(key)}"}}
    end
  end

  defp payload_map(payload, key) do
    case Map.get(payload, key) do
      %{} = m when map_size(m) > 0 -> {:ok, m}
      _ -> {:error, {:unmapped, "payload is missing a non-empty #{inspect(key)} map"}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- reject -------------------------------------------------------------

  @doc """
  Reject a queued proposal. **Soft**: the row persists as `:rejected` (never
  deleted), so later windows reinforce its evidence in place instead of
  re-proposing the same finding from scratch.

  Options: `:reason` (recorded on the row), `:actor`.
  """
  @spec reject_pending(PendingWrite.t() | String.t(), keyword()) ::
          {:ok, PendingWrite.t()} | {:error, :not_found} | {:error, {atom(), String.t()}}
  def reject_pending(row_or_id, opts \\ [])

  def reject_pending(id, opts) when is_binary(id) do
    with {:ok, row} <- get_pending(id), do: reject_pending(row, opts)
  end

  def reject_pending(%PendingWrite{state: state}, _opts) when state in [:applied, :rejected] do
    {:error, {:not_applicable, "state is #{state} — nothing to reject"}}
  end

  def reject_pending(%PendingWrite{} = row, opts) do
    operator = Keyword.get(opts, :actor, "operator")

    attrs = %{
      state: :rejected,
      rejection_reason: Keyword.get(opts, :reason),
      actor: operator
    }

    with {:ok, rejected} <- Ash.update(row, attrs, action: :reject, actor: operator) do
      announce(rejected, :rejected)
      {:ok, rejected}
    end
  end

  @doc "The states a proposal may be in while it is still awaiting a decision."
  @spec live_states() :: [atom()]
  def live_states, do: @live_states

  defp ash_message(%Ash.Error.Invalid{errors: errors}),
    do: errors |> Enum.map(&Exception.message/1) |> Enum.join("; ")

  defp ash_message(err) when is_exception(err), do: Exception.message(err)
  defp ash_message(err), do: inspect(err)
end
