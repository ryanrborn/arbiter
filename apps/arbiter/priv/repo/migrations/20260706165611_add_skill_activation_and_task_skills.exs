defmodule Arbiter.Repo.Migrations.AddSkillActivationAndTaskSkills do
  @moduledoc """
  Layered skill selection + activation (epic child 3, bd-d5hy7y). Adds:

    * `skills.activation_mode` — how the dispatcher advertises the skill
      (`always_on` auto-invokes `/<name>`; `situational` advertises only).
      Defaults to `situational`.
    * `skills.code_only` — restrict the skill to code-producing tasks
      (feature/bug/chore). Defaults to `false`.
    * `issues.skills` — the per-task selection override (opt_out/only/add/
      remove/activation), the task layer of layered skill selection.

  Hand-written (not via `mix ash_sqlite.generate_migrations`) because the
  tracked resource snapshots have drifted from several already-migrated
  resources (bead_id→task_id, tracker_context_*, installation_settings, …);
  the generator would otherwise fold that unrelated backlog into this file. We
  add DB-level defaults so the NOT NULL `skills` columns are safe on any
  existing rows.
  """

  use Ecto.Migration

  def up do
    alter table(:skills) do
      add :activation_mode, :text, null: false, default: "situational"
      add :code_only, :boolean, null: false, default: false
    end

    alter table(:issues) do
      add :skills, :map, default: %{}
    end
  end

  def down do
    alter table(:issues) do
      remove :skills
    end

    alter table(:skills) do
      remove :code_only
      remove :activation_mode
    end
  end
end
