defmodule Arbiter.MCP.Tools.Skills do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the system-wide skill registry:
  `skill_create` / `skill_update` / `skill_delete` / `skill_list` / `skill_get`.
  Split out of `Arbiter.MCP.Tools` (see its moduledoc) — called back into for
  the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  require Logger

  # ---- skill_create -------------------------------------------------------

  @doc """
  Create a system-wide skill (bd-cj6i08). Coordinator only (enforced in
  `Arbiter.MCP.Catalog`). Requires `name` (unique, kebab-case) and `body`
  (markdown); optional `metadata` (object). The registry is NOT
  workspace-scoped — one definition is shared across the whole system.

  A `warning` is returned (non-fatal) when the name collides with a bundled
  skill; the create still succeeds.
  """
  @spec skill_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_create(%Scope{} = scope, args) do
    with {:ok, name} <- Tools.require_string(args, "name"),
         {:ok, body} <- Tools.require_string(args, "body"),
         {:ok, code_only} <- Tools.fetch_optional_bool(args, "code_only"),
         {:ok, workspace_id} <- skill_write_scope(scope, args) do
      attrs =
        %{"name" => name, "body" => body}
        |> Tools.maybe_put("metadata", Tools.fetch_map(args, "metadata"))
        |> Tools.maybe_put("activation_mode", Tools.fetch_string(args, "activation_mode"))
        |> Tools.maybe_put("code_only", code_only)
        |> Tools.maybe_put("workspace_id", workspace_id)

      case Arbiter.Skills.create_skill(attrs, actor: Arbiter.PaperTrail.actor_label(scope)) do
        {:ok, skill} ->
          Logger.info(
            "[skill_create] skill #{skill.id} (#{skill.name}) created" <>
              scope_suffix(skill.workspace_id)
          )

          {:ok, skill |> serialize_skill() |> with_bundled_warning(skill.name)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # READ scope for skill_list / skill_get, honouring isolation:
  #   * a `workspace` arg (id or name) → that workspace (a worker may only name
  #     its own; a coordinator may name any).
  #   * no arg → the scope's bound workspace (worker) or `nil` (a
  #     workspace-agnostic coordinator sees every skill).
  # Returns `{:ok, ws_id | nil}` or `{:error, {:unauthorized, _}}`.
  defp skill_scope(%Scope{} = scope, args), do: Tools.authorized_workspace(scope, args)

  # WRITE scope for skill_create / skill_update. A skill is GLOBAL by default
  # (preserving prior behaviour); scoping is opt-in via an explicit `workspace`
  # arg. So a workspace-bound coordinator does not silently scope every skill it
  # authors to its own workspace — it must ask. Authorisation of the named
  # workspace still runs (a worker could only ever name its own).
  defp skill_write_scope(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "workspace") do
      nil -> {:ok, nil}
      _ref -> Tools.authorized_workspace(scope, args)
    end
  end

  defp scope_suffix(nil), do: " [global]"
  defp scope_suffix(ws_id), do: " [workspace #{ws_id}]"

  # ---- skill_update -------------------------------------------------------

  @doc """
  Update a system-wide skill by `skill` (id or name). Coordinator only. Any
  subset of `name` / `body` / `metadata` may be supplied. Returns the updated
  skill, with a non-fatal bundled-collision `warning` when the (new) name
  collides with a bundled skill.
  """
  @spec skill_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_update(%Scope{} = scope, args) do
    with {:ok, ref} <- Tools.require_string(args, "skill"),
         {:ok, workspace_id} <- skill_write_scope(scope, args),
         {:ok, skill} <- fetch_skill_in_scope(ref, workspace_id),
         {:ok, code_only} <- Tools.fetch_optional_bool(args, "code_only") do
      attrs =
        %{}
        |> Tools.maybe_put("name", Tools.fetch_string(args, "name"))
        |> Tools.maybe_put("body", Tools.fetch_string(args, "body"))
        |> Tools.maybe_put("metadata", Tools.fetch_map(args, "metadata"))
        |> Tools.maybe_put("activation_mode", Tools.fetch_string(args, "activation_mode"))
        |> Tools.maybe_put("code_only", code_only)

      case Arbiter.Skills.update_skill(skill, attrs, actor: Arbiter.PaperTrail.actor_label(scope)) do
        {:ok, updated} ->
          Logger.info("[skill_update] skill #{updated.id} (#{updated.name}) updated")
          {:ok, updated |> serialize_skill() |> with_bundled_warning(updated.name)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- skill_delete -------------------------------------------------------

  @doc """
  Delete a system-wide skill by `skill` (id or name). Coordinator only.
  Returns `{deleted: true, id, name}`.
  """
  @spec skill_delete(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_delete(%Scope{} = _scope, args) do
    with {:ok, ref} <- Tools.require_string(args, "skill"),
         {:ok, skill} <- fetch_skill(ref) do
      case Arbiter.Skills.delete_skill(skill) do
        :ok ->
          Logger.info("[skill_delete] skill #{skill.id} (#{skill.name}) deleted")
          {:ok, %{deleted: true, id: skill.id, name: skill.name}}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  defp fetch_skill(ref) do
    case Arbiter.Skills.get_skill(ref) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:not_found, "no skill matching #{inspect(ref)}"}}
    end
  end

  # Scope-aware fetch for the read/write skill tools. A UUID ref is looked up
  # directly, then checked against the caller's workspace scope; a name ref
  # resolves with shadowing precedence within that scope
  # (`Arbiter.Skills.resolve_skill/2`). `workspace_id` nil = global scope
  # (a workspace-agnostic coordinator sees every skill).
  defp fetch_skill_in_scope(ref, workspace_id) do
    if uuid_ref?(ref) do
      with {:ok, skill} <- fetch_skill(ref) do
        if skill_visible?(skill, workspace_id),
          do: {:ok, skill},
          else: {:error, {:not_found, "no skill matching #{inspect(ref)}"}}
      end
    else
      case Arbiter.Skills.resolve_skill(ref, workspace_id) do
        {:ok, skill} -> {:ok, skill}
        {:error, :not_found} -> {:error, {:not_found, "no skill matching #{inspect(ref)}"}}
      end
    end
  end

  # A global skill is visible in any scope; a scoped skill only in its own
  # workspace. A `nil` caller scope (workspace-agnostic coordinator) sees all.
  defp skill_visible?(_skill, nil), do: true
  defp skill_visible?(%Arbiter.Skills.Skill{workspace_id: nil}, _ws_id), do: true
  defp skill_visible?(%Arbiter.Skills.Skill{workspace_id: ws}, ws_id), do: ws == ws_id

  defp uuid_ref?(ref) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      ref
    )
  end

  # ---- skill_list -----------------------------------------------------------

  @doc """
  List all system-wide skills (names + metadata, no `body`), ordered by name.
  Available to both tiers — a coordinator or any worker can discover what's
  in the registry on demand, the same source of truth as worktree
  materialization.
  """
  @spec skill_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_list(%Scope{} = scope, args) do
    with {:ok, workspace_id} <- skill_scope(scope, args) do
      # A concrete workspace id → the effective (shadowed) set for it: globals
      # overlaid by that workspace's scoped skills. `nil` (a workspace-agnostic
      # coordinator with no filter) → every skill across all scopes. A worker's
      # scope is always workspace-bound, so it can only ever see its own
      # workspace's effective set — never the whole registry (bd-9j6is7 auth).
      skills =
        case workspace_id do
          nil -> Arbiter.Skills.list_skills()
          ws_id -> Arbiter.Skills.list_skills(workspace_id: ws_id)
        end
        |> Enum.map(&serialize_skill_summary/1)

      {:ok, %{skills: skills, count: length(skills)}}
    end
  end

  # ---- skill_get ------------------------------------------------------------

  @doc """
  Fetch one system-wide skill's full markdown body by `skill` (id or name).
  Available to both tiers, so the coordinator (which is not worktree-isolated
  and can't rely on materialization) or any agent can pull a skill body on
  demand from the same registry workers are materialized from.
  """
  @spec skill_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_get(%Scope{} = scope, args) do
    with {:ok, ref} <- Tools.require_string(args, "skill"),
         {:ok, workspace_id} <- skill_scope(scope, args),
         {:ok, skill} <- fetch_skill_in_scope(ref, workspace_id) do
      {:ok, serialize_skill(skill)}
    end
  end

  defp serialize_skill_summary(%Arbiter.Skills.Skill{} = skill) do
    %{
      id: skill.id,
      name: skill.name,
      workspace_id: skill.workspace_id,
      scope: skill_scope_label(skill),
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: Tools.iso(skill.created_at),
      updated_at: Tools.iso(skill.updated_at)
    }
  end

  defp serialize_skill(%Arbiter.Skills.Skill{} = skill) do
    %{
      id: skill.id,
      name: skill.name,
      workspace_id: skill.workspace_id,
      scope: skill_scope_label(skill),
      body: skill.body,
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: Tools.iso(skill.created_at),
      updated_at: Tools.iso(skill.updated_at)
    }
  end

  defp skill_scope_label(%Arbiter.Skills.Skill{workspace_id: nil}), do: "global"
  defp skill_scope_label(%Arbiter.Skills.Skill{}), do: "workspace"

  # Attach a non-fatal bundled-skill collision warning to a serialized skill,
  # or leave it untouched when there is no collision.
  defp with_bundled_warning(map, name) do
    case Arbiter.Skills.bundled_collision(name) do
      nil -> map
      warning -> Map.put(map, :warning, warning)
    end
  end
end
