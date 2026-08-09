defmodule Arbiter.Repo.Migrations.AddLoopPendingWrites do
  @moduledoc """
  Creates `loop_pending_writes` + its AshPaperTrail version table — the Stage 2
  loop-engineering proposal queue (bd-9j2g3x, epic #1011).

  Before this, `Arbiter.Loop.Analysis` suggestions existed only in stdout: next
  week's pass recomputed from a fresh window with no memory that a finding had
  ever been raised, and a below-bar finding (correctly declined at n=1) was
  discarded, so its third occurrence started counting from zero.

  The interesting column is `fingerprint`: a deterministic digest of `{kind,
  target, category, difficulty, repo}`. The partial unique index over
  `(fingerprint, state)` — restricted to the two pre-application states
  `hypothesis` / `proposed` — is the database-level backstop for cross-window
  reinforcement: a later window unions its evidence onto the existing row
  instead of inserting a duplicate. It is deliberately partial so an `applied`
  row does not block a fresh proposal cycle for the same finding.

  Rows are never deleted (invariant: never delete, archive) — rejection is the
  `rejected` state — so there is no soft-delete column.
  """

  use Ecto.Migration

  def up do
    create table(:loop_pending_writes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :kind, :text, null: false
      add :gist, :text, null: false
      add :diff, :text
      add :payload, :map, null: false, default: %{}

      # Pre-registered before application so the goalposts cannot move.
      add :target_metric, :text
      add :baseline, :text

      # The recurring per-dispatch context price of applying this (Amendment D):
      # 0 for a per-task override, non-zero for anything that lands in every
      # future prompt.
      add :context_cost_tokens, :bigint, null: false, default: 0

      add :evidence_count, :bigint, null: false, default: 0
      add :distinct_tasks, :bigint, null: false, default: 0
      add :incident_refs, {:array, :text}, null: false, default: []
      add :task_refs, {:array, :text}, null: false, default: []

      add :scope, :text, null: false, default: "fleet"
      add :state, :text, null: false, default: "hypothesis"

      # The cross-window match key and its inputs, kept for audit.
      add :fingerprint, :text, null: false
      add :category, :text
      add :target, :text
      add :difficulty, :bigint
      add :repo, :text

      add :origin, :text
      # Non-nil means the promotion escalation was already posted — the guard
      # that makes the mailbox post exactly-once.
      add :escalated_at, :utc_datetime_usec
      add :applied_at, :utc_datetime_usec
      add :rejection_reason, :text

      # Reserved for the follow-up re-grading pass; never written here.
      add :outcome_checked_at, :utc_datetime_usec
      add :outcome_delta, :map

      add :actor, :text

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "loop_pending_writes_workspace_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          )

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:loop_pending_writes, [:fingerprint])
    create index(:loop_pending_writes, [:state])

    create index(:loop_pending_writes, [:fingerprint, :state],
             name: "loop_pending_writes_live_fingerprint_index",
             unique: true,
             where: "state IN ('hypothesis', 'proposed')"
           )

    create table(:loop_pending_writes_versions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      add :version_source_id,
          references(:loop_pending_writes,
            column: :id,
            name: "loop_pending_writes_versions_version_source_id_fkey",
            type: :uuid
          ),
          null: false

      add :version_action_name, :text, null: false
      add :version_action_type, :text, null: false
      add :version_action_inputs, :map, null: false
      add :changes, :map

      # `attributes_as_attributes` snapshots these onto every version row so an
      # apply/reject decision is readable without diffing `changes`.
      add :actor, :text
      add :state, :text, null: false
      add :evidence_count, :bigint, null: false
      add :distinct_tasks, :bigint, null: false

      add :version_inserted_at, :utc_datetime_usec, null: false
      add :version_updated_at, :utc_datetime_usec, null: false
    end

    create index(:loop_pending_writes_versions, [:version_source_id])
  end

  def down do
    drop table(:loop_pending_writes_versions)

    drop_if_exists index(:loop_pending_writes, [:fingerprint, :state],
                     name: "loop_pending_writes_live_fingerprint_index"
                   )

    drop_if_exists index(:loop_pending_writes, [:state])
    drop_if_exists index(:loop_pending_writes, [:fingerprint])

    drop table(:loop_pending_writes)
  end
end
