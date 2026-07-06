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
  Create a skill. `attrs` accepts `:name` / `"name"`, `:body` / `"body"`, and
  optional `:metadata` / `"metadata"`. Returns `{:ok, %Skill{}}` or
  `{:error, term}` (validation, or a unique-name collision).
  """
  @spec create_skill(map()) :: {:ok, Skill.t()} | {:error, term()}
  def create_skill(attrs) when is_map(attrs), do: Ash.create(Skill, attrs)

  @doc """
  Update a skill (by id, name, or a loaded struct) with `attrs`
  (`:name` / `:body` / `:metadata`, any subset). Returns `{:ok, %Skill{}}` or
  `{:error, term}`.
  """
  @spec update_skill(Skill.t() | String.t(), map()) :: {:ok, Skill.t()} | {:error, term()}
  def update_skill(%Skill{} = skill, attrs) when is_map(attrs), do: Ash.update(skill, attrs)

  def update_skill(id_or_name, attrs) when is_binary(id_or_name) and is_map(attrs) do
    with {:ok, skill} <- get_skill(id_or_name) do
      update_skill(skill, attrs)
    end
  end

  @doc "Delete a skill (by id, name, or a loaded struct)."
  @spec delete_skill(Skill.t() | String.t()) :: :ok | {:error, term()}
  def delete_skill(%Skill{} = skill), do: Ash.destroy(skill)

  def delete_skill(id_or_name) when is_binary(id_or_name) do
    with {:ok, skill} <- get_skill(id_or_name) do
      delete_skill(skill)
    end
  end

  @doc "List all skills, ordered by name."
  @spec list_skills() :: [Skill.t()]
  def list_skills do
    Skill
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
  end

  @doc """
  Fetch one skill by UUID id or by `name`. Returns `{:ok, %Skill{}}` or
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

  @doc "Fetch one skill by its unique `name`."
  @spec get_skill_by_name(String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_skill_by_name(name) when is_binary(name) do
    case Ash.get(Skill, %{name: name}) do
      {:ok, skill} -> {:ok, skill}
      {:error, _} -> {:error, :not_found}
    end
  end

  # A v4/v7 UUID (as emitted by uuid_v7_primary_key) — distinguishes an id
  # lookup from a name lookup. Names are kebab-case and never match this.
  defp uuid?(s) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      s
    )
  end
end
