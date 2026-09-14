defmodule Arbiter.Repo.Migrations.CreateReviewCoverage do
  @moduledoc """
  P0 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.1.
  Creates the append-only `review_coverage` table. **Nothing reads or
  writes it outside `Arbiter.Reviews.Coverage` yet** — that's P1.

  Written by hand rather than via `mix ash.codegen`, matching the existing
  `create_provider_accounts` migration: this repo's committed
  `priv/resource_snapshots` have already drifted from several hand-written
  migrations, so codegen tries to "catch up" every drifted resource at
  once. This migration was written by hand instead, scoped to the one new
  table. Unlike `create_provider_accounts`, no matching
  `priv/resource_snapshots/repo/review_coverage` snapshot was committed, so
  the next `mix ash.codegen` run will detect this resource as new and emit
  another `create table(:review_coverage)` migration; that migration
  should be a no-op reconciliation (or discarded) rather than applied.
  """

  use Ecto.Migration

  def up do
    create table(:review_coverage, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :task_id, :text, null: false
      add :mr_ref, :text, null: false
      add :head_sha, :text, null: false
      add :base_ref, :text, null: false
      add :net_diff_id, :text, null: false
      add :kind, :text, null: false
      add :source, :text, null: false
      add :round, :bigint

      add :derived_from,
          references(:review_coverage,
            column: :id,
            name: "review_coverage_derived_from_fkey",
            type: :uuid,
            on_delete: :nothing
          )

      add :covered_at, :utc_datetime_usec, null: false
    end

    create unique_index(:review_coverage, [:mr_ref, :head_sha, :kind],
             name: "review_coverage_mr_head_kind_index"
           )

    create index(:review_coverage, [:task_id], name: "review_coverage_task_id_index")
  end

  def down do
    drop_if_exists unique_index(:review_coverage, [:mr_ref, :head_sha, :kind],
                     name: "review_coverage_mr_head_kind_index"
                   )

    drop_if_exists index(:review_coverage, [:task_id], name: "review_coverage_task_id_index")

    drop table(:review_coverage)
  end
end
