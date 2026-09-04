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

  ## Where the work lives

  This module is the queue's public API and its record/reinforce/promote path.
  Applying a proposal is `Arbiter.Loop.Apply` (validate → side effect →
  persist → notify, each step public and separately testable); fan-out is
  `Arbiter.Loop.Notify`.
  """

  use Ash.Domain

  alias Arbiter.Loop.{Apply, Notify, PendingWrite}
  alias Arbiter.Messages.Message
  alias Arbiter.Quota
  alias Arbiter.Tasks.{Issue, Workspace}

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
    |> Enum.map_join("|", &(candidate |> fetch(&1) |> canonicalise()))
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

    with {:ok, workspace_id} <-
           resolve_workspace_id(scope, fetch(candidate, :workspace_id), fetch(candidate, :target)) do
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
        workspace_id: workspace_id
      }

      with {:ok, row} <- Ash.create(PendingWrite, attrs, action: :propose, actor: actor) do
        announce(row, :recorded)
        maybe_escalate(row, actor)
      end
    end
  end

  # A `:fleet` candidate with no workspace of its own (the primary path: `arb
  # loop analyze --propose` without `--workspace`) is attributed to the
  # installation's default workspace — the same fallback `Notify.workspace_id/1`
  # already used for escalation — rather than left as a null FK. That null was
  # the exact shape of #1011 Stage 0 defect G3 (nil `workspace_id` on
  # `usage_events`, fixed in #1016); `PendingWrite` must not reintroduce it.
  #
  # `default_workspace_id/0` deliberately errors when the install is ambiguous
  # (several workspaces, none named "default") rather than guessing — a
  # genuinely cross-workspace finding has no representation here, so record/2
  # refuses it instead of writing an unscoped row.
  defp resolve_workspace_id(:fleet, workspace_id, _target) when workspace_id in [nil, ""],
    do: Quota.default_workspace_id()

  # A `:task` candidate with no workspace of its own is attributed via its
  # `target` task's own workspace — the same rule
  # `PendingWriteWorkspaceBackfill` applies to historical rows — falling back
  # to the install default when the task cannot be found or carries none
  # itself. This must be total: leaving a `:task` row's `workspace_id: nil`
  # reintroduces the exact null-FK defect this function exists to close (the
  # `arb loop analyze --propose` path with no `--workspace` stamps every
  # `:difficulty_override` candidate with `workspace_id: nil`), and a null row
  # is no longer visible-everywhere once `pending_visible?` stopped matching
  # nil — it is invisible instead.
  defp resolve_workspace_id(:task, workspace_id, target) when workspace_id in [nil, ""] do
    case target && Ash.get(Issue, target) do
      {:ok, %Issue{workspace_id: ws_id}} when is_binary(ws_id) and ws_id != "" ->
        {:ok, ws_id}

      _ ->
        Quota.default_workspace_id()
    end
  end

  defp resolve_workspace_id(_scope, workspace_id, _target), do: {:ok, workspace_id}

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

    # A pre-existing row left with `workspace_id: nil` (written before this
    # fix, or by a caller that bypassed `insert/3`) is repaired opportunistically
    # on the next reinforcement rather than left null forever — `insert/3` is
    # the only place a new row is created, but `reinforce/4` is the only place
    # an old one is ever touched again.
    workspace_id =
      if is_nil(existing.workspace_id) do
        case resolve_workspace_id(existing.scope, nil, existing.target) do
          {:ok, ws_id} -> ws_id
          {:error, _reason} -> nil
        end
      else
        existing.workspace_id
      end

    attrs = %{
      incident_refs: incident_refs,
      task_refs: task_refs,
      evidence_count: length(incident_refs),
      distinct_tasks: length(task_refs),
      state: state,
      workspace_id: workspace_id,
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
  defp context_cost_tokens(gist, _scope, _kind, payload), do: prose_tokens(payload, gist)

  @doc """
  The recurring per-dispatch price of the prose a fleet-wide row would land.

  Body before clause before gist, because that is the order of how much of the
  prompt the row actually adds (bd-5w8h0r):

    * `"body"` — a `:skill_create` row authors the whole skill file, stub
      preamble *and* clause. The preamble is carried by every dispatch that
      materializes the skill, so pricing only the clause under-reads the row
      by around a third.
    * `"clause"` — a `:skill_patch` row carries no body; `Apply` splices the
      clause into whatever the skill says at apply time, so the clause is the
      whole of the addition.
    * gist — a row with neither yet (a mid-analysis candidate). The one-line
      summary an operator reads once in `arb loop pending` is a floor, not a
      real price; it under-reads authored prose by roughly an order of
      magnitude, on a figure whose entire purpose is that "a fleet-wide prompt
      addition cannot be approved without its price visible".

  Public so the bd-5w8h0r backfill prices a re-authored row exactly as
  `record/2` would have, rather than re-implementing this precedence and
  drifting from it.
  """
  @spec prose_tokens(map() | nil, String.t() | nil) :: non_neg_integer()
  def prose_tokens(payload, gist) do
    cond do
      is_binary(body = payload && Map.get(payload, "body")) and body != "" ->
        estimate_tokens(body)

      is_binary(clause = payload && Map.get(payload, "clause")) and clause != "" ->
        estimate_tokens(clause)

      is_binary(gist) ->
        estimate_tokens(gist)

      true ->
        0
    end
  end

  @doc """
  The recurring per-dispatch token price of `text`.

  Tokens, not bytes (Amendment D item 4). Skill clauses skew toward paths,
  flags and code fragments, which tokenize far worse than prose, so a byte
  count under-reads exactly the content most likely to be added. ~4 chars per
  token is the standard rule of thumb for English; the ceiling keeps a short
  clause from rounding down to zero and reading as free.

  Public as the primitive under `prose_tokens/2`, which is what a caller
  pricing a whole row wants.
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) do
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
    case Notify.workspace_id(row) do
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

  @doc """
  PubSub topic the queue publishes every state change on, for in-process
  subscribers (the `/loop` dashboard). See `Arbiter.Loop.Notify`.
  """
  @spec pubsub_topic() :: String.t()
  defdelegate pubsub_topic(), to: Notify, as: :topic

  defp announce(%PendingWrite{} = row, event), do: Notify.announce(row, event)

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

  @doc """
  Whether `row`'s payload carries enough to satisfy its kind's apply
  preconditions — `nil` when it does, a message naming the gap otherwise.

  Orthogonal to `inapplicable_reason/1` above: that answers whether the
  row's *state* allows applying it (the evidence bar's teeth); this answers
  whether the payload it carries is enough to apply *as written*, regardless
  of state — a `:hypothesis` can be payload-complete, and a `:proposed` row
  can still be missing authoring (bd-bldypb). Delegates to
  `Apply.payload_ready?/1`, the same check `Apply.side_effect/2` runs, so
  this label and the apply path cannot disagree about what "applicable"
  means. Runs no side effect.
  """
  @spec authoring_gap(PendingWrite.t()) :: String.t() | nil
  def authoring_gap(%PendingWrite{} = row) do
    case Apply.payload_ready?(row) do
      :ok -> nil
      {:error, {_code, message}} -> message
    end
  end

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

  The pipeline itself lives in `Arbiter.Loop.Apply` as four independently
  callable steps — `validate/1`, `side_effect/2`, `persist/2`, `notify/1` —
  so the no-auto-apply discipline can be asserted on the guard alone.
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
    Apply.run(row, Keyword.get(opts, :actor, "operator"))
  end

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
end
