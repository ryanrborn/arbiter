defmodule Arbiter.Skills.ScopingVersioningTest do
  @moduledoc """
  Domain-level tests for `Arbiter.Skills`: workspace scoping + shadowing,
  `paper_trail` version history with actor attribution, and skill-body
  rollback (bd-9j6is7). The broader CRUD surface lives in
  `Arbiter.SkillsTest` (test/arbiter/skills_test.exs).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Skills
  alias Arbiter.Skills.Skill
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  setup do
    {:ok, ws_a} = Ash.create(Workspace, %{name: "ws-a", prefix: "wa"})
    {:ok, ws_b} = Ash.create(Workspace, %{name: "ws-b", prefix: "wb"})
    %{ws_a: ws_a, ws_b: ws_b}
  end

  describe "workspace scoping" do
    test "a skill is global (workspace_id nil) by default" do
      {:ok, skill} = Skills.create_skill(%{name: "tdd", body: "# global"})
      assert skill.workspace_id == nil
    end

    test "a workspace-scoped skill and a same-named global skill coexist", %{ws_a: ws_a} do
      {:ok, global} = Skills.create_skill(%{name: "tdd", body: "# global"})
      {:ok, scoped} = Skills.create_skill(%{name: "tdd", body: "# ws-a", workspace_id: ws_a.id})

      assert global.workspace_id == nil
      assert scoped.workspace_id == ws_a.id
      refute global.id == scoped.id

      all = Skill |> Ash.read!() |> Enum.filter(&(&1.name == "tdd"))
      assert length(all) == 2
    end

    test "two globals with the same name are rejected (global uniqueness preserved)" do
      {:ok, _} = Skills.create_skill(%{name: "tdd", body: "# a"})
      assert {:error, _} = Skills.create_skill(%{name: "tdd", body: "# b"})
    end

    test "two scoped skills with the same name in the same workspace are rejected", %{ws_a: ws_a} do
      {:ok, _} = Skills.create_skill(%{name: "tdd", body: "# a", workspace_id: ws_a.id})

      assert {:error, _} =
               Skills.create_skill(%{name: "tdd", body: "# b", workspace_id: ws_a.id})
    end
  end

  describe "resolve_skill/2 shadowing precedence" do
    test "a workspace-scoped skill shadows the global for that workspace", %{ws_a: ws_a} do
      {:ok, _global} = Skills.create_skill(%{name: "tdd", body: "# global"})
      {:ok, _scoped} = Skills.create_skill(%{name: "tdd", body: "# ws-a", workspace_id: ws_a.id})

      {:ok, resolved} = Skills.resolve_skill("tdd", ws_a.id)
      assert resolved.body == "# ws-a"
      assert resolved.workspace_id == ws_a.id
    end

    test "another workspace with no scoped skill still resolves the global", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      {:ok, _global} = Skills.create_skill(%{name: "tdd", body: "# global"})
      {:ok, _scoped} = Skills.create_skill(%{name: "tdd", body: "# ws-a", workspace_id: ws_a.id})

      {:ok, resolved} = Skills.resolve_skill("tdd", ws_b.id)
      assert resolved.body == "# global"
      assert resolved.workspace_id == nil
    end

    test "nil workspace resolves the global" do
      {:ok, _global} = Skills.create_skill(%{name: "tdd", body: "# global"})
      {:ok, resolved} = Skills.resolve_skill("tdd", nil)
      assert resolved.workspace_id == nil
    end

    test "a scoped skill with no global counterpart resolves in its workspace only", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      {:ok, _scoped} =
        Skills.create_skill(%{name: "wa-only", body: "# only", workspace_id: ws_a.id})

      assert {:ok, _} = Skills.resolve_skill("wa-only", ws_a.id)
      assert {:error, :not_found} = Skills.resolve_skill("wa-only", ws_b.id)
    end
  end

  describe "isolation: editing a scoped skill does not change another workspace" do
    test "editing ws-a's scoped skill leaves ws-b resolving the original global", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      {:ok, _global} = Skills.create_skill(%{name: "tdd", body: "# global v1"})

      {:ok, scoped} =
        Skills.create_skill(%{name: "tdd", body: "# ws-a v1", workspace_id: ws_a.id})

      {:ok, _} = Skills.update_skill(scoped, %{body: "# ws-a v2"})

      {:ok, in_a} = Skills.resolve_skill("tdd", ws_a.id)
      {:ok, in_b} = Skills.resolve_skill("tdd", ws_b.id)

      assert in_a.body == "# ws-a v2"
      assert in_b.body == "# global v1"
    end
  end

  describe "paper_trail version history + actor attribution" do
    test "each create/update produces a version row" do
      {:ok, skill} = Skills.create_skill(%{name: "tdd", body: "# v1"})
      {:ok, _} = Skills.update_skill(skill, %{body: "# v2"})

      versions = Skills.skill_versions(skill)
      assert length(versions) == 2
    end

    test "the actor is recorded on each version" do
      {:ok, skill} = Skills.create_skill(%{name: "tdd", body: "# v1"}, actor: "coordinator")
      {:ok, _} = Skills.update_skill(skill, %{body: "# v2"}, actor: "worker:bd-abc123")

      actors =
        skill
        |> Skills.skill_versions()
        |> Enum.map(& &1.actor)
        |> Enum.sort()

      assert actors == ["coordinator", "worker:bd-abc123"]
    end
  end

  describe "rollback" do
    test "a prior skill body can be retrieved and restored" do
      {:ok, skill} = Skills.create_skill(%{name: "tdd", body: "# original"})
      {:ok, skill} = Skills.update_skill(skill, %{body: "# broken edit"})

      # The create version holds the original body.
      original_version =
        skill
        |> Skills.skill_versions()
        |> Enum.find(&(&1.version_action_type == :create))

      assert original_version.body == "# original"

      {:ok, restored} =
        Skills.restore_skill_version(skill, original_version.id, actor: "coordinator")

      assert restored.body == "# original"

      # The restore itself is an update, so it is captured as a new version.
      assert length(Skills.skill_versions(skill)) == 3
    end
  end
end
