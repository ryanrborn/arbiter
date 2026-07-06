defmodule ArbiterWeb.Api.SkillControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Skills

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/skills" do
    test "creates a skill", %{conn: conn} do
      conn = post(conn, ~p"/api/skills", %{name: "tdd", body: "write test first"})

      body = json_response(conn, 201)
      assert body["name"] == "tdd"
      assert body["body"] == "write test first"
      assert is_binary(body["id"])
      refute Map.has_key?(body, "warning")
    end

    test "returns a warning on bundled-name collision", %{conn: conn} do
      conn = post(conn, ~p"/api/skills", %{name: "code-review", body: "shadow"})

      body = json_response(conn, 201)
      assert body["name"] == "code-review"
      assert body["warning"] =~ "collides with a bundled skill"
    end

    test "returns 422 on an invalid name", %{conn: conn} do
      conn = post(conn, ~p"/api/skills", %{name: "Not Kebab", body: "x"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 422 on a duplicate name", %{conn: conn} do
      {:ok, _} = Skills.create_skill(%{name: "dup", body: "a"})
      conn = post(conn, ~p"/api/skills", %{name: "dup", body: "b"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/skills" do
    test "lists skills", %{conn: conn} do
      {:ok, _} = Skills.create_skill(%{name: "alpha", body: "x"})
      {:ok, _} = Skills.create_skill(%{name: "beta", body: "y"})

      body = json_response(get(conn, ~p"/api/skills"), 200)
      names = Enum.map(body["data"], & &1["name"])
      assert "alpha" in names and "beta" in names
    end
  end

  describe "GET /api/skills/:id" do
    test "fetches by id", %{conn: conn} do
      {:ok, skill} = Skills.create_skill(%{name: "byid", body: "x"})
      body = json_response(get(conn, ~p"/api/skills/#{skill.id}"), 200)
      assert body["id"] == skill.id
    end

    test "fetches by name", %{conn: conn} do
      {:ok, _} = Skills.create_skill(%{name: "byname", body: "x"})
      body = json_response(get(conn, ~p"/api/skills/byname"), 200)
      assert body["name"] == "byname"
    end

    test "returns 404 for an unknown skill", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/skills/nope"), 404)
    end
  end

  describe "PATCH /api/skills/:id" do
    test "updates body by name", %{conn: conn} do
      {:ok, _} = Skills.create_skill(%{name: "patchme", body: "v1"})
      conn = patch(conn, ~p"/api/skills/patchme", %{body: "v2"})
      body = json_response(conn, 200)
      assert body["body"] == "v2"
    end
  end

  describe "DELETE /api/skills/:id" do
    test "deletes a skill", %{conn: conn} do
      {:ok, skill} = Skills.create_skill(%{name: "delme", body: "x"})
      assert json_response(delete(conn, ~p"/api/skills/#{skill.id}"), 200)
      assert {:error, :not_found} = Skills.get_skill("delme")
    end

    test "returns 404 for an unknown skill", %{conn: conn} do
      assert json_response(delete(conn, ~p"/api/skills/nope"), 404)
    end
  end
end
