defmodule Arbiter.Skills.SeedsTest do
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Skills
  alias Arbiter.Skills.Seeds
  alias Arbiter.Tasks.Workspace

  defp fetch_workspace!(name) do
    Workspace
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!()
  end

  describe "seed!/0 — skill registry" do
    test "creates the 3 built-in skills with the documented activation/scope" do
      assert :ok = Seeds.seed!()

      {:ok, tdd} = Skills.get_skill_by_name("test-driven-development")
      assert tdd.activation_mode == :always_on
      assert tdd.code_only == true
      assert tdd.body =~ "RED"
      assert tdd.metadata["description"] =~ "failing test"

      {:ok, verify} = Skills.get_skill_by_name("verification-before-completion")
      assert verify.activation_mode == :always_on
      assert verify.code_only == false
      assert verify.body =~ "arb done"

      {:ok, debug} = Skills.get_skill_by_name("systematic-debugging")
      assert debug.activation_mode == :situational
      assert debug.code_only == false
      assert debug.body =~ "Reproduce"
    end

    test "is idempotent and never overwrites an operator edit" do
      assert :ok = Seeds.seed!()

      {:ok, tdd} = Skills.get_skill_by_name("test-driven-development")
      {:ok, edited} = Skills.update_skill(tdd, %{body: "# my custom TDD body"})

      assert :ok = Seeds.seed!()

      {:ok, unchanged} = Skills.get_skill_by_name("test-driven-development")
      assert unchanged.body == edited.body
      assert unchanged.body == "# my custom TDD body"
    end

    test "re-running does not create duplicates" do
      assert :ok = Seeds.seed!()
      assert :ok = Seeds.seed!()

      names = Skills.list_skills() |> Enum.map(& &1.name)
      assert Enum.sort(Enum.uniq(names)) == Enum.sort(names)

      for name <- Seeds.seed_names() do
        assert Enum.count(names, &(&1 == name)) == 1
      end
    end
  end

  describe "seed!/0 — default workspace wiring" do
    test "lists the seed skills in the default workspace's config when one exists" do
      {:ok, _ws} = Ash.create(Workspace, %{name: "default"})

      assert :ok = Seeds.seed!()

      ws = fetch_workspace!("default")
      assert ws.config["skills"]["workspace"] == Seeds.seed_names()
    end

    test "does not overwrite an operator-configured skills list" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "default",
          config: %{"skills" => %{"workspace" => ["custom-skill"]}}
        })

      assert :ok = Seeds.seed!()

      reloaded = fetch_workspace!("default")
      assert reloaded.config["skills"]["workspace"] == ["custom-skill"]
      assert ws.id == reloaded.id
    end

    test "is a no-op when no default workspace exists yet" do
      assert :ok = Seeds.seed!()

      assert Skills.list_skills() |> Enum.map(& &1.name) |> Enum.sort() ==
               Enum.sort(Seeds.seed_names())
    end
  end
end
