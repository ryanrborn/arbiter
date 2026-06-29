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
    prevent an issue from becoming ready. The Conductor (C3) consumes this edge
    at dispatch time to avoid co-dispatching two conflicting directives.

  ## Gating vs non-gating edges

  Only `:blocks` and `:depends_on` gate readiness (i.e. appear in
  `Issue.ready/0`). All other edge types — `:relates_to`, `:discovered_from`,
  `:parent_of`, and `:conflicts_with` — are non-gating: they carry semantic
  meaning but do not prevent an issue from being picked up.

  ## Constraints

  * `(from_issue_id, to_issue_id, type)` is unique. The same edge cannot be
    declared twice with the same type.
  * `from_issue_id != to_issue_id` — a task cannot depend on itself.
  * Both FKs (`from_issue_id`, `to_issue_id`) must reference real `Issue` rows.
    SQLite enforces this via FK constraints; deleting a referenced issue is
    restricted (matches Issue→Workspace policy).

  ## Not audited

  Dependency edges are intentionally NOT covered by paper_trail. Edges are cheap
  to recreate and the audit overhead isn't worth it for graph metadata. If we
  later want history (e.g. "when was the blocks edge added/removed?") we can
  add `AshPaperTrail.Resource` here without schema changes.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  @types ~w(blocks depends_on relates_to discovered_from parent_of conflicts_with)a

  sqlite do
    table "dependencies"
    repo Arbiter.Repo

    references do
      reference :from_issue, on_delete: :restrict
      reference :to_issue, on_delete: :restrict
    end
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
      non-gating. `:conflicts_with` is symmetric mutual-exclusion (consumed by
      the Conductor at dispatch time, not at readiness evaluation). See module
      doc for full semantics.
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
