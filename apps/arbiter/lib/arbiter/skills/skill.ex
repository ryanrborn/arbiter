defmodule Arbiter.Skills.Skill do
  @moduledoc """
  A `Skill` is a user-authored, reusable instruction module (à la superpowers'
  `SKILL.md`) that arbiter materializes into a worker's worktree at
  `.claude/skills/<name>/SKILL.md` so a `--print` worker discovers and can
  invoke it as `/<name>` (activation confirmed by spike bd-5tc1s0).

  ## System-wide, NOT workspace-scoped

  Skill definitions live **once** for the whole arbiter system — there is no
  `workspace_id`. One "tdd" skill is shared everywhere; the layered selection
  of *which* skills apply to a given worker (workspace / repo / task) is
  resolved later at dispatch time (epic child 3), not by duplicating rows.

  ## Fields

    * `:name` — unique, kebab-case identifier. Doubles as the slash command
      (`/<name>`) and the materialized directory name. Debug output scopes
      names as `{source}:{name}` (e.g. `project:tdd`); the invocable command is
      the unscoped `/tdd`.
    * `:body` — the markdown skill body (the `SKILL.md` contents).
    * `:metadata` — optional free-form map (e.g. `description`, `tags`).

  ## Name collisions with bundled skills

  Every `--print` worker always sees ~20 built-in "bundled" skills
  (`code-review`, `deep-research`, …) regardless of what arbiter materializes
  (spike finding #3). A registry skill whose name collides with a bundled one
  is still allowed — the project-source skill wins for its `/<name>` command —
  but authors are *warned* at author time. The warning is surfaced by the
  callers (`Arbiter.Skills.bundled_collision/1`), not enforced as a DB
  constraint, so an operator can deliberately shadow a bundled skill.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Skills,
    data_layer: AshSqlite.DataLayer

  # Kebab-case: lowercase letters/digits, hyphen-separated, no leading/trailing
  # or doubled hyphens. Mirrors the directory name a worker's skill loader
  # accepts and the `/<name>` slash command.
  @name_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  sqlite do
    table "skills"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :body, :metadata]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :body, :metadata]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true

      constraints max_length: 64,
                  min_length: 1,
                  match: @name_format,
                  trim?: true

      description "Unique kebab-case identifier; the /<name> slash command and materialized dir name."
    end

    attribute :body, :string do
      allow_nil? false
      public? true
      constraints min_length: 1

      description "Markdown skill body — the contents written to .claude/skills/<name>/SKILL.md."
    end

    attribute :metadata, :map do
      public? true
      default %{}

      description "Optional free-form metadata (e.g. description, tags)."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    # Unique name across the whole system. `eager_check?` validates against the
    # DB at changeset time so create/update surface a clean validation error
    # (not a raw constraint violation) on collision.
    identity :unique_name, [:name], eager_check?: true
  end

  @doc "The regex a skill name must match (kebab-case)."
  def name_format, do: @name_format
end
