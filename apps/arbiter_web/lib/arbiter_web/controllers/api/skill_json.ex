defmodule ArbiterWeb.Api.SkillJSON do
  @moduledoc "Render functions for `Arbiter.Skills.Skill` resources."

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
    %{
      id: skill.id,
      name: skill.name,
      body: skill.body,
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: iso(skill.created_at),
      updated_at: iso(skill.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
