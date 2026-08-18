defmodule Arbiter.Repo.Migrations.AddTaskRefToMessages do
  @moduledoc """
  Adds the canonical `task_ref` column to `messages`, alongside the legacy
  `directive_ref` column, and backfills existing rows.

  bd-58vtjk — `directive_ref`'s own doc comment called it "the directive
  task_id this message concerns", using old fleet vernacular where "directive"
  meant plain task/issue. That predates, and is unrelated to, the Graph/
  Conductor `directive` feature (`graph_add_directive` etc., which uses
  `issue_id`). `task_ref` is the unambiguous replacement, matching the
  existing `tracker_ref`/`pr_ref` naming convention.

  `directive_ref` is retained and dual-written by `Message`'s `:create`
  action during the retirement compat window (mirrors #863/#864's
  `@legacy_*` pattern) — drop it once no old producer remains. This is a
  hand-written, messages-only migration, matching the precedent set by
  `20260803200744_add_cleared_at_to_messages.exs`: `mix ash.codegen` folds in
  unrelated snapshot drift from other resources.
  """

  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:task_ref, :text)
    end

    execute(
      "UPDATE messages SET task_ref = directive_ref WHERE directive_ref IS NOT NULL",
      "UPDATE messages SET task_ref = NULL"
    )
  end

  def down do
    alter table(:messages) do
      remove(:task_ref)
    end
  end
end
