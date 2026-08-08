defmodule Arbiter.Skills do
  @moduledoc """
  Ash domain + public API for the system-wide **Skill** registry
  (epic bd-xfc55c, child bd-cj6i08).

  A `Arbiter.Skills.Skill` is a user-authored markdown instruction module that
  arbiter materializes into a worker's worktree at
  `.claude/skills/<name>/SKILL.md` (materialization + layered selection land in
  epic child 3). The registry is **system-wide** — definitions live once for
  the whole arbiter system, not per workspace.

  This module is the entry point for CRUD from every surface (dashboard
  LiveView, the `arb skill` CLI via the REST controller, and the `skill_*` MCP
  tools). They all funnel through `create_skill/1`, `update_skill/2`, and
  `delete_skill/1` so validation and the bundled-skill collision warning are
  applied uniformly.

  ## Bundled-skill collision

  Every `--print` worker always sees ~20 built-in "bundled" skills regardless
  of what arbiter materializes (spike bd-5tc1s0 finding #3). Naming a registry
  skill the same as a bundled one is *allowed* — a worktree/project-source
  skill wins for its `/<name>` command — but the collision is surfaced to the
  author as a non-fatal warning (`bundled_collision/1`). It is deliberately not
  a hard constraint so an operator can knowingly shadow a bundled skill.
  """

  use Ash.Domain

  alias Arbiter.Skills.Skill

  require Ash.Query

  resources do
    resource Skill
    # AshPaperTrail version rows for Skill (bd-9j6is7); queryable via
    # Arbiter.Skills.Skill.Version.
    resource Skill.Version
    # Usage telemetry (bd-61hnbb).
    resource Arbiter.Skills.Usage
  end

  # The built-in skills every `claude --print` worker sees regardless of what
  # arbiter materializes into the worktree (spike bd-5tc1s0 finding #3). Kept
  # as a static list because bundled skills ship with the Claude CLI, not the
  # arbiter DB — this is a best-effort author-time warning, not a hard rule.
  # Update if the CLI's bundled set changes.
  @bundled_skills ~w(
    deep-research
    dataviz
    update-config
    keybindings-help
    verify
    code-review
    simplify
    fewer-permission-prompts
    loop
    schedule
    claude-api
    run
    init
    review
    security-review
  )

  @doc "The known bundled (built-in) skill names a worker always sees."
  @spec bundled_skills() :: [String.t()]
  def bundled_skills, do: @bundled_skills

  @doc "True if `name` collides with a bundled skill name."
  @spec bundled_skill?(String.t()) :: boolean()
  def bundled_skill?(name) when is_binary(name), do: name in @bundled_skills
  def bundled_skill?(_), do: false

  @doc """
  A human-readable collision warning for `name`, or `nil` when there is no
  collision. Callers surface this at author time; it never blocks the write.
  """
  @spec bundled_collision(String.t() | nil) :: String.t() | nil
  def bundled_collision(name) when is_binary(name) do
    if bundled_skill?(name) do
      "\"#{name}\" collides with a bundled skill of the same name — workers " <>
        "always see the built-in one too. The materialized project skill wins " <>
        "for /#{name}, but consider a distinct name to avoid confusion."
    end
  end

  def bundled_collision(_), do: nil

  # ---- CRUD ---------------------------------------------------------------

  @doc """
  Create a skill. `attrs` accepts `:name` / `"name"`, `:body` / `"body"`,
  optional `:metadata` / `"metadata"`, and optional `:workspace_id` /
  `"workspace_id"` (`nil` → a global skill; a workspace id → a workspace-scoped
  skill that shadows a same-named global there — see `resolve_skill/2`).

  `opts[:actor]` is normalised via `Arbiter.PaperTrail.actor_label/1` and
  recorded on the resulting paper-trail version so the write is attributable.

  Returns `{:ok, %Skill{}}` or `{:error, term}` (validation, or a unique-name
  collision within the scope).
  """
  @spec create_skill(map(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def create_skill(attrs, opts \\ []) when is_map(attrs) do
    Ash.create(Skill, put_actor(attrs, opts), actor: actor(opts))
  end

  @doc """
  Update a skill (by id, name, or a loaded struct) with `attrs`
  (`:name` / `:body` / `:metadata`, any subset). A skill's `workspace_id`
  (scope) is fixed at creation and cannot be changed here.

  `opts[:actor]` is recorded on the resulting version (see `create_skill/2`).
  Returns `{:ok, %Skill{}}` or `{:error, term}`.
  """
  @spec update_skill(Skill.t() | String.t(), map(), keyword()) ::
          {:ok, Skill.t()} | {:error, term()}
  def update_skill(skill_or_ref, attrs, opts \\ [])

  def update_skill(%Skill{} = skill, attrs, opts) when is_map(attrs) do
    with {:ok, updated} <- Ash.update(skill, put_actor(attrs, opts), actor: actor(opts)) do
      # Increment patch_count (best-effort; don't let telemetry break the update).
      _ = increment_usage(skill.id, :patch_count)
      {:ok, updated}
    end
  end

  def update_skill(id_or_name, attrs, opts) when is_binary(id_or_name) and is_map(attrs) do
    with {:ok, skill} <- get_skill(id_or_name) do
      update_skill(skill, attrs, opts)
    end
  end

  # Thread the caller-supplied actor into the changeset both as the Ash
  # `actor:` option (for anything that reads it) and as the `actor` attribute
  # that paper_trail snapshots onto the version. Never sourced from tool args.
  defp actor(opts), do: Keyword.get(opts, :actor)

  defp put_actor(attrs, opts) do
    case Arbiter.PaperTrail.actor_label(actor(opts)) do
      nil -> attrs
      label -> Map.put(attrs, actor_key(attrs), label)
    end
  end

  # Match the key style already in `attrs` so we don't mix atom/string keys.
  defp actor_key(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "actor", else: :actor
  end

  @doc "Delete a skill (by id, name, or a loaded struct)."
  @spec delete_skill(Skill.t() | String.t()) :: :ok | {:error, term()}
  def delete_skill(%Skill{} = skill), do: Ash.destroy(skill)

  def delete_skill(id_or_name) when is_binary(id_or_name) do
    with {:ok, skill} <- get_skill(id_or_name) do
      delete_skill(skill)
    end
  end

  @doc """
  List skills, ordered by name.

  Opts:

    * `:workspace_id` — when given, return the **effective** set for that
      workspace: every global skill plus that workspace's scoped skills, with a
      scoped skill shadowing a same-named global (the scoped row wins). Passing
      `nil` returns only global skills. Omitting the option returns *every* row
      (all scopes), which is what the dashboard / `arb skill list` show.
  """
  @spec list_skills(keyword()) :: [Skill.t()]
  def list_skills(opts \\ []) do
    if Keyword.has_key?(opts, :workspace_id) do
      list_effective_skills(Keyword.get(opts, :workspace_id))
    else
      Skill
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!()
    end
  end

  # The effective, shadowed set for a workspace: globals overlaid by that
  # workspace's scoped skills (scoped wins on a name collision).
  defp list_effective_skills(workspace_id) do
    Skill
    |> Ash.Query.filter(is_nil(workspace_id) or workspace_id == ^workspace_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, rows} ->
      Enum.find(rows, hd(rows), &(&1.workspace_id == workspace_id))
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Fetch one skill by UUID id or by global `name`. A bare name resolves the
  **global** skill (`workspace_id` nil); use `resolve_skill/2` for
  workspace-aware, shadowing lookup. Returns `{:ok, %Skill{}}` or
  `{:error, :not_found}`.
  """
  @spec get_skill(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_skill(id_or_name) when is_binary(id_or_name) do
    if uuid?(id_or_name) do
      case Ash.get(Skill, id_or_name) do
        {:ok, skill} -> {:ok, skill}
        {:error, _} -> {:error, :not_found}
      end
    else
      get_skill_by_name(id_or_name)
    end
  end

  @doc "Fetch the **global** skill (workspace_id nil) with this `name`."
  @spec get_skill_by_name(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_skill_by_name(name) when is_binary(name), do: fetch_scoped(name, nil)

  @doc """
  Resolve `name` for `workspace_id`, honouring shadowing precedence:

      workspace-scoped `name` in that workspace  →  global `name`  →  not found

  `workspace_id` `nil` resolves the global directly. This is the resolver the
  dispatch-time skill selection (`Arbiter.Skills.Selection`) uses so a
  workspace-scoped body shadows the global for that workspace only.
  """
  @spec resolve_skill(String.t(), String.t() | nil) ::
          {:ok, Skill.t()} | {:error, :not_found}
  def resolve_skill(name, nil) when is_binary(name), do: fetch_scoped(name, nil)

  def resolve_skill(name, workspace_id) when is_binary(name) and is_binary(workspace_id) do
    case fetch_scoped(name, workspace_id) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> fetch_scoped(name, nil)
    end
  end

  # Exact-scope fetch: the one row matching (name, workspace_id) or not_found.
  # `nil` must match via `is_nil` — Ash `field == nil` does not compile to a
  # SQL `IS NULL`, so a `nil`-workspace (global) lookup needs the split clause.
  defp fetch_scoped(name, nil) do
    Skill
    |> Ash.Query.filter(name == ^name and is_nil(workspace_id))
    |> read_one_skill()
  end

  defp fetch_scoped(name, workspace_id) do
    Skill
    |> Ash.Query.filter(name == ^name and workspace_id == ^workspace_id)
    |> read_one_skill()
  end

  defp read_one_skill(query) do
    case Ash.read_one(query) do
      {:ok, %Skill{} = skill} -> {:ok, skill}
      _ -> {:error, :not_found}
    end
  end

  # ---- Version history / rollback (bd-9j6is7) -----------------------------

  @doc """
  All paper-trail versions for a skill, newest first. Each version carries the
  `body` (and other snapshotted attributes), `actor`, `version_action_type`,
  and `version_action_name`, so a prior body can be inspected before
  `restore_skill_version/3`.
  """
  @spec skill_versions(Skill.t() | String.t()) :: [Skill.Version.t()]
  def skill_versions(%Skill{id: id}), do: versions_for(id)

  def skill_versions(id_or_name) when is_binary(id_or_name) do
    case get_skill(id_or_name) do
      {:ok, skill} -> versions_for(skill.id)
      {:error, _} -> []
    end
  end

  defp versions_for(skill_id) do
    Skill.Version
    |> Ash.Query.filter(version_source_id == ^skill_id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!()
  end

  @doc """
  Restore a skill's `body` (and `metadata`) to a prior version. `version_id` is
  the id of a `Skill.Version` row (from `skill_versions/1`). The restore is
  itself an ordinary update, so it produces a new version — history is
  append-only, never rewritten. `opts[:actor]` attributes the restore.

  Returns `{:ok, %Skill{}}`, `{:error, :not_found}` if the skill or version is
  unknown, or `{:error, :version_mismatch}` if the version belongs to a
  different skill.
  """
  @spec restore_skill_version(Skill.t() | String.t(), String.t(), keyword()) ::
          {:ok, Skill.t()} | {:error, term()}
  def restore_skill_version(skill_or_ref, version_id, opts \\ [])

  def restore_skill_version(%Skill{} = skill, version_id, opts) when is_binary(version_id) do
    with {:ok, version} <- fetch_version(version_id),
         :ok <- ensure_version_of(version, skill) do
      update_skill(skill, %{body: version.body, metadata: version.metadata || %{}}, opts)
    end
  end

  def restore_skill_version(id_or_name, version_id, opts) when is_binary(id_or_name) do
    with {:ok, skill} <- get_skill(id_or_name) do
      restore_skill_version(skill, version_id, opts)
    end
  end

  defp fetch_version(version_id) do
    case Ash.get(Skill.Version, version_id) do
      {:ok, version} -> {:ok, version}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp ensure_version_of(version, %Skill{id: id}) do
    if version.version_source_id == id, do: :ok, else: {:error, :version_mismatch}
  end

  # A v4/v7 UUID (as emitted by uuid_v7_primary_key) — distinguishes an id
  # lookup from a name lookup. Names are kebab-case and never match this.
  defp uuid?(s) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      s
    )
  end

  # ---- Usage telemetry (bd-61hnbb) ----------------------------------------

  @doc """
  Get or create a usage row for a skill. Returns `{:ok, %Usage{}}`.
  """
  @spec get_or_create_usage(String.t()) :: {:ok, Arbiter.Skills.Usage.t()} | {:error, term()}
  def get_or_create_usage(skill_id) when is_binary(skill_id) do
    case Arbiter.Skills.Usage
         |> Ash.Query.filter(skill_id == ^skill_id)
         |> Ash.read_one() do
      {:ok, %Arbiter.Skills.Usage{} = usage} ->
        {:ok, usage}

      {:ok, nil} ->
        # No existing usage row; create one
        Ash.create(Arbiter.Skills.Usage, %{skill_id: skill_id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Increment a usage counter for a skill. `counter` is `:materialize_count`,
  `:invoke_count`, or `:patch_count`. Also updates the corresponding
  `last_*_at` timestamp. Wraps errors and logs them so a telemetry failure
  never crashes the dispatch.

  Returns `{:ok, %Usage{}}` or `{:error, term()}`.
  """
  @spec increment_usage(String.t(), :materialize_count | :invoke_count | :patch_count) ::
          {:ok, Arbiter.Skills.Usage.t()} | {:error, term()}
  def increment_usage(skill_id, counter)
      when is_binary(skill_id) and counter in [:materialize_count, :invoke_count, :patch_count] do
    with {:ok, usage} <- get_or_create_usage(skill_id) do
      current_value = Map.fetch!(usage, counter)

      attrs = %{
        counter => (current_value || 0) + 1,
        timestamp_for(counter) => DateTime.utc_now()
      }

      Ash.update(usage, attrs)
    end
  end

  defp timestamp_for(:materialize_count), do: :last_materialized_at
  defp timestamp_for(:invoke_count), do: :last_invoked_at
  defp timestamp_for(:patch_count), do: :last_patched_at
end
