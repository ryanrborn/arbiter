defmodule Arbiter.MCP.SkillToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Skills

  setup do
    coordinator = %Scope{
      tier: :coordinator,
      workspace_id: "ws-#{System.unique_integer([:positive])}"
    }

    worker = %Scope{tier: :worker, workspace_id: "ws-1", task_id: "bd-1"}
    {:ok, coordinator: coordinator, worker: worker}
  end

  describe "skill_create/2" do
    test "creates a skill", %{coordinator: sc} do
      assert {:ok, result} =
               Tools.skill_create(sc, %{"name" => "tdd", "body" => "write test first"})

      assert result.name == "tdd"
      assert result.body == "write test first"
      assert is_binary(result.id)
      refute Map.has_key?(result, :warning)
    end

    test "attaches a warning on bundled-name collision but still creates", %{coordinator: sc} do
      assert {:ok, result} = Tools.skill_create(sc, %{"name" => "code-review", "body" => "x"})
      assert result.name == "code-review"
      assert result.warning =~ "collides with a bundled skill"
      assert {:ok, _} = Skills.get_skill("code-review")
    end

    test "errors on a missing name", %{coordinator: sc} do
      assert {:error, {:invalid, msg}} = Tools.skill_create(sc, %{"body" => "x"})
      assert msg =~ "name"
    end

    test "errors on a duplicate name", %{coordinator: sc} do
      {:ok, _} = Tools.skill_create(sc, %{"name" => "dup", "body" => "a"})
      assert {:error, {:invalid, _}} = Tools.skill_create(sc, %{"name" => "dup", "body" => "b"})
    end
  end

  describe "skill_update/2" do
    test "updates by name", %{coordinator: sc} do
      {:ok, _} = Skills.create_skill(%{name: "up", body: "v1"})
      assert {:ok, result} = Tools.skill_update(sc, %{"skill" => "up", "body" => "v2"})
      assert result.body == "v2"
    end

    test "errors on unknown skill", %{coordinator: sc} do
      assert {:error, {:not_found, _}} =
               Tools.skill_update(sc, %{"skill" => "ghost", "body" => "x"})
    end
  end

  describe "skill_delete/2" do
    test "deletes by id", %{coordinator: sc} do
      {:ok, skill} = Skills.create_skill(%{name: "del", body: "x"})
      assert {:ok, %{deleted: true, name: "del"}} = Tools.skill_delete(sc, %{"skill" => skill.id})
      assert {:error, :not_found} = Skills.get_skill("del")
    end

    test "errors on unknown skill", %{coordinator: sc} do
      assert {:error, {:not_found, _}} = Tools.skill_delete(sc, %{"skill" => "ghost"})
    end
  end

  describe "skill_list/2" do
    test "lists skills ordered by name, without body", %{coordinator: sc} do
      {:ok, _} = Skills.create_skill(%{name: "zeta", body: "z"})
      {:ok, _} = Skills.create_skill(%{name: "alpha", body: "a"})

      assert {:ok, %{skills: skills, count: count}} = Tools.skill_list(sc, %{})
      assert count == 2
      assert Enum.map(skills, & &1.name) == ["alpha", "zeta"]
      refute Map.has_key?(hd(skills), :body)
    end

    test "available to a worker scope too", %{worker: wk} do
      {:ok, _} = Skills.create_skill(%{name: "for-workers", body: "x"})
      assert {:ok, %{count: 1}} = Tools.skill_list(wk, %{})
    end
  end

  describe "skill_get/2" do
    test "fetches full body by name", %{coordinator: sc} do
      {:ok, _} = Skills.create_skill(%{name: "getme", body: "the full body"})
      assert {:ok, result} = Tools.skill_get(sc, %{"skill" => "getme"})
      assert result.name == "getme"
      assert result.body == "the full body"
    end

    test "fetches by id", %{coordinator: sc} do
      {:ok, skill} = Skills.create_skill(%{name: "getbyid", body: "v"})
      assert {:ok, result} = Tools.skill_get(sc, %{"skill" => skill.id})
      assert result.name == "getbyid"
    end

    test "available to a worker scope too", %{worker: wk} do
      {:ok, _} = Skills.create_skill(%{name: "for-worker-get", body: "v"})
      assert {:ok, result} = Tools.skill_get(wk, %{"skill" => "for-worker-get"})
      assert result.body == "v"
    end

    test "errors on unknown skill", %{coordinator: sc} do
      assert {:error, {:not_found, _}} = Tools.skill_get(sc, %{"skill" => "ghost"})
    end

    test "errors on missing skill arg", %{coordinator: sc} do
      assert {:error, {:invalid, msg}} = Tools.skill_get(sc, %{})
      assert msg =~ "skill"
    end
  end

  describe "catalog tier visibility" do
    test "skill_create/update/delete are coordinator-only, not visible to workers", %{
      coordinator: sc,
      worker: wk
    } do
      coord_names = Catalog.visible(sc) |> Enum.map(& &1.name)
      worker_names = Catalog.visible(wk) |> Enum.map(& &1.name)

      for name <- ~w(skill_create skill_update skill_delete) do
        assert name in coord_names, "#{name} should be visible to coordinator"
        refute name in worker_names, "#{name} should NOT be visible to worker"
      end
    end

    test "skill_list/skill_get are visible to both tiers", %{coordinator: sc, worker: wk} do
      coord_names = Catalog.visible(sc) |> Enum.map(& &1.name)
      worker_names = Catalog.visible(wk) |> Enum.map(& &1.name)

      for name <- ~w(skill_list skill_get) do
        assert name in coord_names, "#{name} should be visible to coordinator"
        assert name in worker_names, "#{name} should be visible to worker"
      end
    end

    test "a worker calling skill_create is rejected at the tier gate", %{worker: wk} do
      assert {:rpc_error, _code, msg} =
               Catalog.call(wk, "skill_create", %{"name" => "x", "body" => "y"})

      assert msg =~ "not permitted"
    end

    test "coordinator call goes through the catalog end-to-end", %{coordinator: sc} do
      assert {:ok, result} =
               Catalog.call(sc, "skill_create", %{"name" => "via-catalog", "body" => "b"})

      assert result.name == "via-catalog"
    end

    test "a worker call to skill_get goes through the catalog end-to-end", %{
      coordinator: sc,
      worker: wk
    } do
      {:ok, _} = Catalog.call(sc, "skill_create", %{"name" => "catalog-get", "body" => "body"})

      assert {:ok, result} = Catalog.call(wk, "skill_get", %{"skill" => "catalog-get"})
      assert result.body == "body"
    end
  end
end
