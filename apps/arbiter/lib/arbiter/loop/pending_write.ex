defmodule Arbiter.Loop.PendingWrite do
  @moduledoc """
  A **reviewable proposal** produced by the loop-analysis pass (Stage 2 of the
  loop-engineering epic, bd-9j2g3x).

  Stage 1 (`Arbiter.Loop.Analysis`) computes suggestions and prints them. They
  existed only in stdout, so next week's pass recomputed from a fresh window
  with no memory that a finding had ever been raised — and a below-bar finding
  (correctly declined at n=1) was discarded entirely, so its third occurrence
  three weeks later started counting from zero.

  A `PendingWrite` is that suggestion, persisted. It is **inert**: a queued row
  is not an effect. Nothing is ever auto-applied at any evidence level — an
  operator applies or rejects it through `Arbiter.Loop`.

  ## States

    * `:hypothesis` — recorded, but below the evidence bar. Accumulates
      evidence across windows; not applicable.
    * `:proposed` — cleared the bar (or is `:task`-scoped, blast-radius 1).
      Applicable, and escalated to the coordinator mailbox exactly once.
    * `:applied` — an operator applied it; `applied_at` is stamped.
    * `:rejected` — an operator declined it. **Soft**: the row persists so the
      same finding is not re-proposed from scratch, and later windows keep
      reinforcing its evidence in place.
    * `:superseded` — replaced by a later proposal.

  Rows are never deleted (invariant 3: never delete, archive), so this resource
  deliberately has no `:destroy` action.

  ## Cross-window accumulation

  `fingerprint` is a deterministic digest of `{kind, target, category,
  difficulty, repo}` — never an LLM comparison. A later window that produces
  the same fingerprint **reinforces** the existing row (unions `incident_refs`
  / `task_refs`, recomputes `evidence_count` / `distinct_tasks`) instead of
  inserting a duplicate. The partial unique index over `(fingerprint, state)`
  restricted to the two live states is the database-level backstop.

  ## Pre-registration

  `target_metric` and `baseline` are copied from the suggestion and recorded
  **before** the change is applied, so the goalposts cannot move afterwards.
  They are refreshed while the row is still un-applied (each window remeasures
  the same baseline) and frozen once `state` is `:applied`.

  `outcome_delta` / `outcome_checked_at` are **reserved** here and populated by
  the follow-up re-grading pass — not by this resource or by `Arbiter.Loop`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Loop,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  sqlite do
    table "loop_pending_writes"
    repo Arbiter.Repo

    references do
      # Every live row is owned by a workspace, `:fleet`-scoped included
      # (bd-3dasqm) — `scope: :fleet` is the sole fleet marker; a nil
      # `workspace_id` is not a second way to say "fleet-wide" (that was
      # #1011 Stage 0 defect G3's shape on `usage_events`, fixed in #1016,
      # and this resource must not reintroduce it on a different table).
      reference :workspace, on_delete: :delete
    end

    custom_indexes do
      # At most one *live* row per fingerprint+state. Restricted to the two
      # pre-application states so an `:applied` row does not block a fresh
      # proposal cycle for the same finding (a recurrence after an apply is a
      # new hypothesis — the re-grading pass reads it as the fix not landing).
      index [:fingerprint, :state],
        unique: true,
        where: "state IN ('hypothesis', 'proposed')",
        name: "loop_pending_writes_live_fingerprint_index"

      index [:state]
      index [:fingerprint]
    end
  end

  # Version every write: applying or rejecting a proposal is an operator
  # decision that must be attributable after the fact.
  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    attributes_as_attributes([:actor, :state, :evidence_count, :distinct_tasks])
    ignore_attributes([:created_at, :updated_at])
  end

  actions do
    defaults [:read]

    create :propose do
      primary? true

      accept [
        :kind,
        :gist,
        :diff,
        :payload,
        :target_metric,
        :baseline,
        :context_cost_tokens,
        :evidence_count,
        :distinct_tasks,
        :incident_refs,
        :task_refs,
        :scope,
        :state,
        :fingerprint,
        :category,
        :target,
        :difficulty,
        :repo,
        :origin,
        :actor,
        :workspace_id
      ]
    end

    # Cross-window reinforcement: union the evidence, recompute the counts, and
    # (for a `:hypothesis` that just crossed the bar) promote.
    update :reinforce do
      require_atomic? false

      accept [
        :incident_refs,
        :task_refs,
        :evidence_count,
        :distinct_tasks,
        :state,
        :gist,
        :baseline,
        :target_metric,
        :context_cost_tokens,
        :diff,
        :payload,
        :actor
      ]
    end

    # The exactly-once escalation guard. Timestamps are set by the action rather
    # than accepted as input: `store_action_inputs?(true)` serialises every
    # accepted attribute into the version row, and AshPaperTrail loses a
    # `:utc_datetime_usec` NewType's `precision` constraint on the way, so an
    # accepted microsecond timestamp is dumped as `:utc_datetime` and rejected.
    update :mark_escalated do
      require_atomic? false
      accept [:actor]
      change set_attribute(:escalated_at, &DateTime.utc_now/0)
    end

    update :mark_applied do
      require_atomic? false
      accept [:state, :actor]
      change set_attribute(:applied_at, &DateTime.utc_now/0)
    end

    update :reject do
      require_atomic? false
      accept [:state, :rejection_reason, :actor]
    end

    # Reserved for the follow-up re-grading pass (out of scope here).
    update :record_outcome do
      require_atomic? false
      accept [:outcome_delta, :actor]
      change set_attribute(:outcome_checked_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :skill_patch,
                    :skill_create,
                    :difficulty_override,
                    :config_set,
                    :repo_doc_patch
                  ]

      description "What applying this proposal does; dispatched on by Arbiter.Loop.apply_pending/2."
    end

    attribute :gist, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true

      description "One-line operator-facing summary, shown in `arb loop pending` and the dashboard list."
    end

    attribute :diff, :string do
      public? true
      description "Unified diff of the change, when one can be rendered ahead of application."
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
      default %{}

      description ~s[What apply needs, keyed by `kind` (e.g. %{"task_id" => …, "difficulty" => …}).]
    end

    attribute :target_metric, :string do
      public? true

      description "The metric this change is supposed to move — pre-registered before application."
    end

    attribute :baseline, :string do
      public? true
      description "That metric's value at proposal time — pre-registered before application."
    end

    attribute :context_cost_tokens, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0

      description """
      Recurring per-dispatch context price of applying this proposal, in tokens
      (Amendment D). 0 for a per-task override — blast radius 1 is charged once,
      not forever. Non-zero for anything that lands in every future prompt, so a
      fleet-wide prompt addition cannot be approved without its price visible.
      """
    end

    attribute :evidence_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0

      description "Number of distinct incidents backing this proposal (== length(incident_refs))."
    end

    attribute :distinct_tasks, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0

      description "Number of distinct tasks the incidents span (== length(task_refs))."
    end

    attribute :incident_refs, {:array, :string} do
      allow_nil? false
      public? true
      default []

      description "Run ids of the incidents backing this proposal, unioned across windows."
    end

    attribute :task_refs, {:array, :string} do
      allow_nil? false
      public? true
      default []

      description "Task ids the incidents span, unioned across windows; the source of distinct_tasks."
    end

    attribute :scope, :atom do
      allow_nil? false
      public? true
      default :fleet
      constraints one_of: [:fleet, :task]

      description ":fleet changes routing/skills for everyone and must clear the evidence bar; :task is blast-radius 1 and bypasses it."
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :hypothesis
      constraints one_of: [:proposed, :hypothesis, :applied, :rejected, :superseded]

      description "Lifecycle state; only :proposed is applicable."
    end

    attribute :fingerprint, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128

      description "Deterministic digest of {kind, target, category, difficulty, repo} — the cross-window match key."
    end

    attribute :category, :string do
      public? true

      description "The finding category the proposal came from; a fingerprint input, kept for audit."
    end

    attribute :target, :string do
      public? true

      description "What the change targets (task id, skill name/id, config path); a fingerprint input."
    end

    attribute :difficulty, :integer do
      public? true

      description "Difficulty cell the finding was observed in; a fingerprint input. nil for fleet-wide."
    end

    attribute :repo, :string do
      public? true

      description "Repo cell the finding was observed in; a fingerprint input. nil for fleet-wide."
    end

    attribute :origin, :string do
      public? true
      description "What produced this row (e.g. \"loop.analyze\")."
    end

    attribute :escalated_at, :utc_datetime_usec do
      public? true

      description "When the promotion to :proposed was posted to the escalation mailbox. Non-nil means already posted — the guard that makes escalation exactly-once."
    end

    attribute :applied_at, :utc_datetime_usec do
      public? true
      description "When an operator applied this proposal."
    end

    attribute :rejection_reason, :string do
      public? true

      description "Why an operator rejected it. Rejection is soft — the row persists as :rejected."
    end

    attribute :outcome_checked_at, :utc_datetime_usec do
      public? true
      description "Reserved for the re-grading pass: when the outcome was measured."
    end

    attribute :outcome_delta, :map do
      public? true

      description "Reserved for the re-grading pass: the measured movement in target_metric after application."
    end

    attribute :actor, :string do
      public? true

      description ~s[Stable label of the actor who last wrote this row (e.g. "coordinator", "loop"). Never read from untrusted MCP input.]
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? true
      public? true
      attribute_writable? true

      description """
      Owning workspace. Nullable per #1130, but `Arbiter.Loop.record/2` always
      resolves a real workspace for a live row — a `:fleet`-scoped candidate
      with none of its own is attributed to the installation's default
      workspace rather than left nil (bd-3dasqm). A nil here should only be
      seen on a row written before that fix and not yet backfilled.
      """
    end
  end
end
