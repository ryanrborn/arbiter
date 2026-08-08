defmodule ArbiterWeb.Api.SkillJSON do
  @moduledoc "Render functions for `Arbiter.Skills.Skill` resources."

  require Ash.Query

  alias Arbiter.Skills.Skill

  def index(%{skills: skills}) do
    %{data: Enum.map(skills, &data/1)}
  end

  # `show` optionally carries a non-fatal bundled-collision warning (create /
  # update); it is omitted entirely when there is no collision.
  def show(%{skill: skill} = assigns) do
    case Map.get(assigns, :warning) do
      nil -> data(skill)
      warning -> Map.put(data(skill), :warning, warning)
    end
  end

  def data(%Skill{} = skill) do
    usage = load_usage(skill.id)

    %{
      id: skill.id,
      name: skill.name,
      body: skill.body,
      workspace_id: skill.workspace_id,
      scope: if(is_nil(skill.workspace_id), do: "global", else: "workspace"),
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: iso(skill.created_at),
      updated_at: iso(skill.updated_at),
      materialize_count: usage.materialize_count,
      invoke_count: usage.invoke_count,
      patch_count: usage.patch_count,
      last_materialized_at: iso(usage.last_materialized_at),
      last_invoked_at: iso(usage.last_invoked_at),
      last_patched_at: iso(usage.last_patched_at)
    }
  end

  defp load_usage(skill_id) do
    query = Ash.Query.filter(Arbiter.Skills.Usage, skill_id == ^skill_id)

    case Ash.read_one(query) do
      {:ok, usage} when not is_nil(usage) -> usage
      _ -> empty_usage()
    end
  end

  defp empty_usage do
    %Arbiter.Skills.Usage{
      materialize_count: 0,
      invoke_count: 0,
      patch_count: 0,
      last_materialized_at: nil,
      last_invoked_at: nil,
      last_patched_at: nil
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
