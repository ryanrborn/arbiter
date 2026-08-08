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
      # bd-d5hy7y: activation/scope default to the safe "advertise, any task" values.
      assert skill.activation_mode == :situational
      assert skill.code_only == false
      assert %DateTime{} = skill.created_at
    end

    test "accepts activation_mode and code_only (bd-d5hy7y)" do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "tdd-strict",
          body: "# TDD",
          activation_mode: :always_on,
          code_only: true
        })

      assert skill.activation_mode == :always_on
      assert skill.code_only == true
    end

    test "casts a string activation_mode (MCP/REST shape) and rejects an invalid one" do
      {:ok, skill} =
        Skills.create_skill(%{
          "name" => "always-skill",
          "body" => "b",
          "activation_mode" => "always_on"
        })

      assert skill.activation_mode == :always_on

      assert {:error, %Ash.Error.Invalid{}} =
               Skills.create_skill(%{name: "bad-mode", body: "b", activation_mode: :sometimes})
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

  test "the resource is workspace-scopable (workspace_id attribute, nil = global)" do
    # bd-9j6is7: skills gained an optional workspace_id; nil is a global skill
    # (the original behaviour), preserved as the create default.
    assert :workspace_id in (Skill |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name))

    {:ok, skill} = Skills.create_skill(%{name: "global-by-default", body: "x"})
    assert skill.workspace_id == nil
  end

  describe "Skills.Usage resource" do
    test "tracks materialize_count for a skill" do
      {:ok, skill} = Skills.create_skill(%{name: "test-skill", body: "test body"})

      # Should be able to get or create usage for this skill
      {:ok, usage} = Skills.get_or_create_usage(skill.id)

      assert usage.skill_id == skill.id
      assert usage.materialize_count == 0
      assert usage.invoke_count == 0
      assert usage.patch_count == 0
    end

    test "increments materialize_count" do
      {:ok, skill} = Skills.create_skill(%{name: "material-skill", body: "test"})
      {:ok, _usage} = Skills.get_or_create_usage(skill.id)

      {:ok, updated} = Skills.increment_usage(skill.id, :materialize_count)

      assert updated.materialize_count == 1
      assert updated.last_materialized_at != nil
    end

    test "increments invoke_count" do
      {:ok, skill} = Skills.create_skill(%{name: "invoke-skill", body: "test"})
      {:ok, _usage} = Skills.get_or_create_usage(skill.id)

      {:ok, updated} = Skills.increment_usage(skill.id, :invoke_count)

      assert updated.invoke_count == 1
      assert updated.last_invoked_at != nil
    end

    test "increments patch_count" do
      {:ok, skill} = Skills.create_skill(%{name: "patch-skill", body: "test"})
      {:ok, _usage} = Skills.get_or_create_usage(skill.id)

      {:ok, updated} = Skills.increment_usage(skill.id, :patch_count)

      assert updated.patch_count == 1
      assert updated.last_patched_at != nil
    end

    test "handles multiple increments" do
      {:ok, skill} = Skills.create_skill(%{name: "multi-skill", body: "test"})
      {:ok, _usage} = Skills.get_or_create_usage(skill.id)

      {:ok, _u1} = Skills.increment_usage(skill.id, :materialize_count)
      {:ok, u2} = Skills.increment_usage(skill.id, :materialize_count)
      {:ok, u3} = Skills.increment_usage(skill.id, :invoke_count)

      assert u2.materialize_count == 2
      assert u3.materialize_count == 2
      assert u3.invoke_count == 1
    end
  end
end
