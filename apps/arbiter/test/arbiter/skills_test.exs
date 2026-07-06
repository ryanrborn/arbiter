defmodule Arbiter.SkillsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Skills
  alias Arbiter.Skills.Skill

  describe "create_skill/1" do
    test "creates a skill with minimal attrs" do
      {:ok, skill} = Skills.create_skill(%{name: "tdd", body: "# TDD\nWrite the test first."})

      assert skill.name == "tdd"
      assert skill.body =~ "Write the test first"
      assert skill.metadata == %{}
      assert %DateTime{} = skill.created_at
    end

    test "accepts optional metadata" do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "brainstorm",
          body: "body",
          metadata: %{"description" => "ideation", "tags" => ["design"]}
        })

      assert skill.metadata == %{"description" => "ideation", "tags" => ["design"]}
    end

    test "accepts string-keyed attrs (MCP/REST shape)" do
      {:ok, skill} = Skills.create_skill(%{"name" => "debugging", "body" => "steps"})
      assert skill.name == "debugging"
    end

    test "rejects a missing name" do
      assert {:error, %Ash.Error.Invalid{}} = Skills.create_skill(%{body: "x"})
    end

    test "rejects a missing body" do
      assert {:error, %Ash.Error.Invalid{}} = Skills.create_skill(%{name: "no-body"})
    end

    test "rejects a non-kebab-case name" do
      for bad <- ["Not_Kebab", "has spaces", "UPPER", "trailing-", "-leading", "double--dash"] do
        assert {:error, %Ash.Error.Invalid{}} = Skills.create_skill(%{name: bad, body: "x"}),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "accepts valid kebab-case names" do
      for good <- ["tdd", "test-driven-development", "a1", "systematic-debugging"] do
        assert {:ok, _} = Skills.create_skill(%{name: good, body: "x"}),
               "expected #{inspect(good)} to be accepted"
      end
    end

    test "enforces a unique name" do
      {:ok, _} = Skills.create_skill(%{name: "dup", body: "one"})
      assert {:error, %Ash.Error.Invalid{}} = Skills.create_skill(%{name: "dup", body: "two"})
    end
  end

  describe "update_skill/2" do
    test "updates body and metadata by struct" do
      {:ok, skill} = Skills.create_skill(%{name: "planning", body: "v1"})
      {:ok, updated} = Skills.update_skill(skill, %{body: "v2", metadata: %{"tags" => ["x"]}})

      assert updated.body == "v2"
      assert updated.metadata == %{"tags" => ["x"]}
    end

    test "updates by name" do
      {:ok, _} = Skills.create_skill(%{name: "rename-me", body: "v1"})
      {:ok, updated} = Skills.update_skill("rename-me", %{name: "renamed"})
      assert updated.name == "renamed"
    end

    test "returns not_found for an unknown ref" do
      assert {:error, :not_found} = Skills.update_skill("nope", %{body: "x"})
    end
  end

  describe "delete_skill/1" do
    test "deletes by struct" do
      {:ok, skill} = Skills.create_skill(%{name: "temp", body: "x"})
      assert :ok = Skills.delete_skill(skill)
      assert {:error, :not_found} = Skills.get_skill("temp")
    end

    test "deletes by name" do
      {:ok, _} = Skills.create_skill(%{name: "temp2", body: "x"})
      assert :ok = Skills.delete_skill("temp2")
    end
  end

  describe "get_skill/1 and list_skills/0" do
    test "fetches by id and by name" do
      {:ok, skill} = Skills.create_skill(%{name: "findme", body: "x"})

      assert {:ok, byid} = Skills.get_skill(skill.id)
      assert byid.id == skill.id
      assert {:ok, byname} = Skills.get_skill("findme")
      assert byname.id == skill.id
    end

    test "lists skills sorted by name" do
      {:ok, _} = Skills.create_skill(%{name: "zebra", body: "x"})
      {:ok, _} = Skills.create_skill(%{name: "alpha", body: "x"})

      names = Skills.list_skills() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
      assert "alpha" in names and "zebra" in names
    end
  end

  describe "bundled-skill collision" do
    test "bundled_skill?/1 recognizes built-ins" do
      assert Skills.bundled_skill?("code-review")
      assert Skills.bundled_skill?("deep-research")
      refute Skills.bundled_skill?("my-custom-skill")
    end

    test "bundled_collision/1 warns on a collision, nil otherwise" do
      assert Skills.bundled_collision("code-review") =~ "collides with a bundled skill"
      assert Skills.bundled_collision("my-custom-skill") == nil
    end

    test "a colliding name is still allowed to be created (warning, not a block)" do
      assert {:ok, skill} = Skills.create_skill(%{name: "code-review", body: "shadow"})
      assert skill.name == "code-review"
      assert Skills.bundled_collision(skill.name) != nil
    end
  end

  test "the resource is not workspace-scoped (no workspace_id attribute)" do
    refute :workspace_id in (Skill |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name))
  end
end
