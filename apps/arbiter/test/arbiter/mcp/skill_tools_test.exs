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

  describe "catalog tier visibility" do
    test "skill_* tools are coordinator-only, not visible to workers", %{
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
  end
end
