defmodule Arbiter.Skills.Skill do
  @moduledoc """
  A `Skill` is a user-authored, reusable instruction module (à la superpowers'
  `SKILL.md`) that arbiter materializes into a worker's worktree at
  `.claude/skills/<name>/SKILL.md` so a `--print` worker discovers and can
  invoke it as `/<name>` (activation confirmed by spike bd-5tc1s0).

  ## Scoping: global (default) or workspace-scoped

  A skill has an optional `workspace_id` (bd-9j6is7):

    * `nil` → **global** — the original behaviour, shared by every workspace.
    * a workspace id → **workspace-scoped** — visible only to that workspace.

  A workspace-scoped skill **shadows** a global skill of the same name *for
  that workspace only*. Precedence (see `Arbiter.Skills.resolve_skill/2`):

      workspace-scoped `name` in ws  →  global `name`  →  not found

  So tuning `tdd` for `leotech` (a scoped row) never touches the `default`
  workspace, which keeps resolving the global `tdd`. Global uniqueness is
  preserved (two globals named `tdd` collide); a scoped skill may reuse a
  global's name, and two workspaces may each hold their own `tdd`. This is
  enforced by the `[:name, :workspace_id]` identity with `nils_distinct?:
  false` (so the two `nil`-workspace globals collide, but a global and a
  scoped row do not).

  The layered selection of *which* skills apply to a given worker (workspace /
  repo / task) is resolved at dispatch time (epic child 3), and now resolves
  each name through `resolve_skill/2` so a scoped body shadows the global.

  ## Version history + actor (paper_trail)

  Every create/update is captured as an `AshPaperTrail` version
  (`Arbiter.Skills.Skill.Version`), so a `skill_update` that overwrites `body`
  is recoverable (`Arbiter.Skills.skill_versions/1` +
  `restore_skill_version/3`). Each version snapshots the `actor` that made it —
  a stable string label (`Arbiter.PaperTrail.actor_label/1`) threaded through
  the Ash `actor:` option — so a change is attributable, not just diffable.

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
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  # Kebab-case: lowercase letters/digits, hyphen-separated, no leading/trailing
  # or doubled hyphens. Mirrors the directory name a worker's skill loader
  # accepts and the `/<name>` slash command.
  @name_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  sqlite do
    table "skills"
    repo Arbiter.Repo

    references do
      # A scoped skill is owned by its workspace: deleting the workspace
      # removes its scoped skills. Globals (`workspace_id` nil) are unaffected.
      reference :workspace, on_delete: :delete
    end

    # SQLite treats NULLs as distinct in a unique index, so the identity's
    # `[:name, :workspace_id]` index enforces scoped uniqueness but NOT global
    # uniqueness (it would allow two `name`/NULL globals). ecto_sqlite3 does not
    # support `nulls_distinct: false`, so we enforce global uniqueness with a
    # partial unique index over the globals only. (Application-level
    # `eager_check?` on the identity still gives a clean validation error.)
    custom_indexes do
      index [:name],
        unique: true,
        where: "workspace_id IS NULL",
        name: "skills_unique_global_name_index"
    end
  end

  # Version every write (bd-9j6is7). `attributes_as_attributes` snapshots
  # these fields as top-level columns on **every** version row (not just a
  # diff), so a prior `body` can be read back and restored directly
  # (`Arbiter.Skills.restore_skill_version/3`) and the `actor` is attributable
  # per version. `change_tracking_mode :changes_only` additionally records the
  # per-write diff in `changes` for audit display. `updated_at` churns on every
  # write and carries no audit value.
  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    attributes_as_attributes([:actor, :body, :metadata])
    ignore_attributes([:created_at, :updated_at])
    # Skills are really deleted (`skill_delete`), so do NOT put a FK from the
    # version rows back to the source — it would block the delete. Version
    # history persists (with a final destroy version) after the skill is gone.
    reference_source?(false)
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :body, :metadata, :activation_mode, :code_only, :workspace_id, :actor]
    end

    update :update do
      primary? true
      require_atomic? false
      # `workspace_id` is deliberately NOT accepted: a skill's scope is fixed
      # at creation. `:actor` records who made the edit.
      accept [:name, :body, :metadata, :activation_mode, :code_only, :actor]
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

    # DECISION C (epic child 3, bd-d5hy7y). A materialized skill is only
    # *listed* to a `--print` worker — it is a slash command, not an
    # auto-injected system prompt, so the worker won't follow it unless the
    # dispatch prompt invokes it. The activation mode says how the dispatcher
    # advertises it:
    #
    #   * `:always_on`   — arbiter auto-injects a `/<name>` "use this skill"
    #     directive into the worker prompt for every dispatch in the effective
    #     set (e.g. `tdd`).
    #   * `:situational` — materialized + advertised ("these skills are
    #     available; invoke the relevant one via /name"), leaving invocation to
    #     the agent's judgement (e.g. `systematic-debugging`). Default.
    #
    # A selection layer (workspace / repo / task) may override this per skill.
    attribute :activation_mode, :atom do
      allow_nil? false
      public? true
      default :situational
      constraints one_of: [:situational, :always_on]

      description "How the dispatcher advertises the skill: :always_on auto-invokes /<name>; :situational only advertises it."
    end

    # Scoping refinement (Ryan, 2026-07-06): code-discipline skills (TDD, etc.)
    # only make sense for **code-producing** work. When `true`, the skill is
    # excluded from the effective set entirely for non-code-producing tasks
    # (`decision`, `task`/spike, `epic`), so an always-on skill is never forced
    # onto a task that emits no code. Default `false` (applies to any task).
    attribute :code_only, :boolean do
      allow_nil? false
      public? true
      default false

      description "When true, the skill only applies to code-producing tasks (feature/bug/chore); excluded from decision/task/epic."
    end

    # `last_edited_by` marker: the actor of the most recent write. Snapshotted
    # onto each version row (see the `paper_trail` block) for per-version
    # attribution. Never read from untrusted MCP input — the MCP layer derives
    # it from the caller's scope, never from tool arguments.
    attribute :actor, :string do
      public? true
      allow_nil? true

      description "Stable label of the actor who last wrote this skill (e.g. \"coordinator\", \"worker:bd-…\")."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    # `nil` = global (every workspace). A workspace id scopes the skill to that
    # workspace, where it shadows a same-named global (`resolve_skill/2`).
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? true
      public? true
      attribute_writable? true

      description "Owning workspace; nil means a global skill shared by every workspace."
    end
  end

  identities do
    # Unique name *within a scope*: the DB index over `[:name, :workspace_id]`
    # enforces at most one skill per (name, workspace), letting a scoped skill
    # reuse a global's name and each workspace hold its own. Global uniqueness
    # (at most one `name`/NULL row) is enforced by the partial unique index in
    # the `sqlite` block — SQLite can't do `nulls_distinct: false`.
    # `eager_check?` surfaces a clean validation error (not a raw constraint
    # violation) on collision in either scope, including a duplicate global.
    identity :unique_name, [:name, :workspace_id], eager_check?: true
  end

  @doc "The regex a skill name must match (kebab-case)."
  def name_format, do: @name_format
end
