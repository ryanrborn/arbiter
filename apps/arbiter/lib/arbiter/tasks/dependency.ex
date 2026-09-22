defmodule Arbiter.Tasks.Dependency do
  @moduledoc """
  A `Dependency` is a directed edge between two Issues. Captures the bd notion of
  task-to-task relationships: one task blocks / depends on / relates to / was
  discovered from / is parent of another.

  ## Semantics by `type`

  * `:blocks` — `from_issue` blocks `to_issue`. To work on `to_issue`, you must
    first close `from_issue`. (Inverse of `:depends_on`.)
  * `:depends_on` — `from_issue` depends on `to_issue`. `from_issue` is not
    "ready" until `to_issue` is closed. Gates readiness in `Issue.ready/0`.
  * `:relates_to` — soft relationship. Informational only; does NOT gate
    readiness or block progress.
  * `:discovered_from` — `from_issue` was discovered while working on
    `to_issue`. Informational lineage.
  * `:parent_of` — `from_issue` is a parent (e.g. an epic) of `to_issue`. Does
    not gate readiness, but it *is* the grouping edge: a parent task rolls up
    `{child_closed, child_total}` progress over its `:parent_of` children and,
    when its `auto_close` flag is set, closes once they are all done. See
    `Arbiter.Tasks.Issue.Calcs` and `Arbiter.Tasks.Issue.maybe_auto_close/1`.
  * `:conflicts_with` — mutual-exclusion edge. Expresses "do not run these two
    issues concurrently". **Symmetric**: A conflicts_with B implies B
    conflicts_with A (both directions carry the same meaning). **Non-gating**:
    it does NOT affect `Issue.ready/0` — a conflicting peer being open does not
    prevent an issue from becoming *ready*. It is consumed one step later, at
    **dispatch** time, by `Arbiter.Tasks.EdgeGate` — the predicate the board
    scheduler (`Arbiter.Board.Scheduler` / Autopilot) asks since bd-6bax7s.
    A ready task whose
    counterpart is in flight is held with `blocked — conflicts with <id>
    (<state>)` until that counterpart merges, closes or is parked.

  ## Gating vs non-gating edges

  Only `:blocks` and `:depends_on` gate readiness (i.e. appear in
  `Issue.ready/0`). All other edge types — `:relates_to`, `:discovered_from`,
  `:parent_of`, and `:conflicts_with` — are non-gating: they carry semantic
  meaning but do not prevent an issue from becoming ready.

  "Non-gating" is a statement about *readiness*, not about dispatch.
  `:conflicts_with` is non-gating and still stops a dispatch, because
  readiness is a property of the task and the mutex is a property of the
  moment. `Arbiter.Tasks.EdgeGate` holds both halves of that distinction, and
  is what the board scheduler consults.

  ## Constraints

  * `(from_issue_id, to_issue_id, type)` is unique. The same edge cannot be
    declared twice with the same type.
  * `from_issue_id != to_issue_id` — a task cannot depend on itself.
  * Both FKs (`from_issue_id`, `to_issue_id`) must reference real `Issue` rows.
    SQLite enforces this via FK constraints; deleting a referenced issue is
    restricted (matches Issue→Workspace policy).

  ## Audited

  Edges **are** paper-trailed (bd-apj0gq). They used not to be, on the reasoning
  that "edges are cheap to recreate" — true while every edge was written by a
  script. Once `Arbiter.Tasks.Dependencies` put edge writes behind one facade
  reachable from MCP, REST, the CLI and (next) a browser button, "who added this
  blocker, and when" became an operator question, so every create and destroy
  now writes a `Arbiter.Tasks.Dependency.Version` row. The `dependencies` table
  itself is unchanged; the history lives in `dependencies_versions`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  @types ~w(blocks depends_on relates_to discovered_from parent_of conflicts_with)a

  sqlite do
    table "dependencies"
    repo Arbiter.Repo

    references do
      reference :from_issue, on_delete: :restrict
      reference :to_issue, on_delete: :restrict
    end
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    ignore_attributes([:created_at, :updated_at])
    # Snapshot the edge's identity onto every version row so "bd-a depends_on
    # bd-b was removed on <date>" is readable without diffing `changes` — the
    # destroy version is otherwise an empty diff against a now-deleted row.
    attributes_as_attributes([:from_issue_id, :to_issue_id, :type])
    # No FK from version rows back to `dependencies`: an edge is destroyed, not
    # archived, and its history must not block the destroy (matches Workspace).
    reference_source?(false)
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:from_issue_id, :to_issue_id, :type, :created_by, :notes]

      change {Arbiter.Tasks.Dependency.Changes.RejectSelfReference, []}
    end

    update :update do
      primary? true
      accept [:type, :created_by, :notes]
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :from_issue_id, :string do
      allow_nil? false
      public? true
      description "The dependent issue (e.g. the one that is blocked)."
    end

    attribute :to_issue_id, :string do
      allow_nil? false
      public? true
      description "The dependency target (e.g. the blocker)."
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @types

      description """
      Edge type. Only `:blocks` and `:depends_on` gate readiness; the rest are
      non-gating. `:conflicts_with` is symmetric mutual-exclusion, consumed at
      dispatch time rather than at readiness evaluation — by the board
      scheduler, through `Arbiter.Tasks.EdgeGate`. See module doc for full
      semantics.
      """
    end

    attribute :created_by, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Optional actor identifier; populated when auth lands."
    end

    attribute :notes, :string do
      public? true
      default ""
      description "Markdown. Free-form context on why this edge exists."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :from_issue, Arbiter.Tasks.Issue do
      allow_nil? false
      public? true
      attribute_writable? true
      attribute_type :string
    end

    belongs_to :to_issue, Arbiter.Tasks.Issue do
      allow_nil? false
      public? true
      attribute_writable? true
      attribute_type :string
    end
  end

  identities do
    # Enforced as a UNIQUE index on (from_issue_id, to_issue_id, type).
    # Prevents duplicate edges of the same type between the same pair.
    identity :unique_edge, [:from_issue_id, :to_issue_id, :type]
  end

  @doc "List of valid dependency type atoms."
  def types, do: @types
end
