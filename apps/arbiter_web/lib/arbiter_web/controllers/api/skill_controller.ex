defmodule ArbiterWeb.Api.SkillController do
  @moduledoc """
  REST endpoints for the system-wide `Arbiter.Skills.Skill` registry
  (bd-cj6i08). Backs the `arb skill` CLI.

  Routes:

    * `GET    /api/skills`     — :index
    * `POST   /api/skills`     — :create
    * `GET    /api/skills/:id` — :show  (`:id` is a UUID or the skill name)
    * `PATCH  /api/skills/:id` — :update (also `PUT`)
    * `DELETE /api/skills/:id` — :delete

  Skills are NOT workspace-scoped — one definition is shared across the whole
  arbiter system. `create`/`update` responses include a non-fatal `warning`
  when the name collides with a bundled skill (spike bd-5tc1s0 finding #3).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Skills

  action_fallback ArbiterWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, skills: Skills.list_skills())
  end

  def show(conn, %{"id" => id}) do
    with {:ok, skill} <- Skills.get_skill(id) do
      render(conn, :show, skill: skill)
    end
  end

  def create(conn, params) do
    attrs = Map.take(params, ["name", "body", "metadata"])

    with {:ok, skill} <- Skills.create_skill(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, skill: skill, warning: Skills.bundled_collision(skill.name))
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["name", "body", "metadata"])

    with {:ok, skill} <- Skills.get_skill(id),
         {:ok, updated} <- Skills.update_skill(skill, attrs) do
      render(conn, :show, skill: updated, warning: Skills.bundled_collision(updated.name))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, skill} <- Skills.get_skill(id),
         :ok <- Skills.delete_skill(skill) do
      render(conn, :show, skill: skill)
    end
  end
end
