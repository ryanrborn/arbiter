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

  A skill is global by default; pass `workspace_id` on create to scope it to a
  workspace (where it shadows a same-named global). `GET /api/skills` accepts an
  optional `workspace_id` query param to list a workspace's effective set.
  Writes are attributed to the `"cli"` actor in the paper-trail history.
  `create`/`update` responses include a non-fatal `warning` when the name
  collides with a bundled skill (spike bd-5tc1s0 finding #3).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Skills

  action_fallback ArbiterWeb.Api.FallbackController

  # Attribution label for writes originating at the `arb` CLI / REST surface.
  @actor "cli"

  def index(conn, params) do
    skills =
      case Map.get(params, "workspace_id") do
        nil -> Skills.list_skills()
        ws_id -> Skills.list_skills(workspace_id: ws_id)
      end

    render(conn, :index, skills: skills)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, skill} <- Skills.get_skill(id) do
      render(conn, :show, skill: skill)
    end
  end

  def create(conn, params) do
    attrs =
      Map.take(params, [
        "name",
        "body",
        "metadata",
        "activation_mode",
        "code_only",
        "workspace_id"
      ])

    with {:ok, skill} <- Skills.create_skill(attrs, actor: @actor) do
      conn
      |> put_status(:created)
      |> render(:show, skill: skill, warning: Skills.bundled_collision(skill.name))
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["name", "body", "metadata", "activation_mode", "code_only"])

    with {:ok, skill} <- Skills.get_skill(id),
         {:ok, updated} <- Skills.update_skill(skill, attrs, actor: @actor) do
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
