defmodule Arbiter.Skills.SelectionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Skills
  alias Arbiter.Skills.Selection
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "sel-ws", prefix: "se"})

    # A small registry: tdd (always_on, code_only), debug (situational),
    # elixir-style (situational), docs-helper (situational).
    {:ok, _} =
      Skills.create_skill(%{
        name: "tdd",
        body: "# TDD",
        activation_mode: :always_on,
        code_only: true
      })

    {:ok, _} = Skills.create_skill(%{name: "debug", body: "# Debug"})
    {:ok, _} = Skills.create_skill(%{name: "elixir-style", body: "# Elixir"})
    {:ok, _} = Skills.create_skill(%{name: "docs-helper", body: "# Docs"})

    %{ws: ws}
  end

  defp task(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, issue_type: :feature}, attrs))

    task
  end

  defp names(resolved), do: Enum.map(resolved, & &1.skill.name)

  describe "layered union" do
    test "workspace layer only", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd", "debug"]}}
      resolved = Selection.resolve(task: task(ws), workspace: config, repo: nil)

      assert Enum.sort(names(resolved)) == ["debug", "tdd"]
    end

    test "repo layer adds and removes on top of workspace", %{ws: ws} do
      config = %{
        "skills" => %{
          "workspace" => ["tdd", "debug"],
          "repos" => %{"server" => %{"add" => ["elixir-style"], "remove" => ["debug"]}}
        }
      }

      resolved = Selection.resolve(task: task(ws), workspace: config, repo: "server")

      assert Enum.sort(names(resolved)) == ["elixir-style", "tdd"]
    end

    test "repo layer as a bare list is treated as additions", %{ws: ws} do
      config = %{
        "skills" => %{"workspace" => ["debug"], "repos" => %{"server" => ["elixir-style"]}}
      }

      resolved = Selection.resolve(task: task(ws), workspace: config, repo: "server")
      assert Enum.sort(names(resolved)) == ["debug", "elixir-style"]
    end

    test "unknown skill names are skipped", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd", "ghost-skill"]}}
      resolved = Selection.resolve(task: task(ws), workspace: config, repo: nil)
      assert names(resolved) == ["tdd"]
    end
  end

  describe "per-task layer" do
    test "add / remove adjust the inherited set", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["debug"]}}
      t = task(ws, %{skills: %{"add" => ["elixir-style"], "remove" => ["debug"]}})

      resolved = Selection.resolve(task: t, workspace: config, repo: nil)
      assert names(resolved) == ["elixir-style"]
    end

    test "only replaces the inherited set entirely", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["debug", "tdd"]}}
      t = task(ws, %{skills: %{"only" => ["elixir-style"]}})

      resolved = Selection.resolve(task: t, workspace: config, repo: nil)
      assert names(resolved) == ["elixir-style"]
    end

    test "opt_out yields no skills", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["debug", "tdd"]}}
      t = task(ws, %{skills: %{"opt_out" => true}})

      assert Selection.resolve(task: t, workspace: config, repo: nil) == []
    end
  end

  describe "activation resolution" do
    test "falls back to the skill's own activation_mode", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd", "debug"]}}
      resolved = Selection.resolve(task: task(ws), workspace: config, repo: nil)

      assert %{activation: :always_on} = Enum.find(resolved, &(&1.skill.name == "tdd"))
      assert %{activation: :situational} = Enum.find(resolved, &(&1.skill.name == "debug"))
    end

    test "per-layer override wins over the skill default", %{ws: ws} do
      config = %{
        "skills" => %{"workspace" => [%{"name" => "debug", "activation" => "always_on"}]}
      }

      resolved = Selection.resolve(task: task(ws), workspace: config, repo: nil)
      assert %{activation: :always_on} = Enum.find(resolved, &(&1.skill.name == "debug"))
    end

    test "per-task activation override wins over everything", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd"]}}
      t = task(ws, %{skills: %{"activation" => %{"tdd" => "situational"}}})

      resolved = Selection.resolve(task: t, workspace: config, repo: nil)
      assert %{activation: :situational} = Enum.find(resolved, &(&1.skill.name == "tdd"))
    end
  end

  describe "code-awareness" do
    test "code_only skills are dropped on non-code tasks (decision)", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd", "debug"]}}
      t = task(ws, %{issue_type: :decision})

      resolved = Selection.resolve(task: t, workspace: config, repo: nil)
      # tdd is code_only → dropped; debug (not code_only) stays.
      assert names(resolved) == ["debug"]
    end

    test "code_only skills are dropped on task-type (spike) work", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd"]}}
      t = task(ws, %{issue_type: :task})

      assert Selection.resolve(task: t, workspace: config, repo: nil) == []
    end

    test "code_only skills are kept on code tasks (bug/feature/chore)", %{ws: ws} do
      config = %{"skills" => %{"workspace" => ["tdd"]}}

      for type <- [:feature, :bug, :chore] do
        t = task(ws, %{issue_type: type})
        assert names(Selection.resolve(task: t, workspace: config, repo: nil)) == ["tdd"]
      end
    end

    test "code_producing?/1 classifies issue types", %{ws: _ws} do
      assert Selection.code_producing?(:feature)
      assert Selection.code_producing?(:bug)
      assert Selection.code_producing?(:chore)
      refute Selection.code_producing?(:decision)
      refute Selection.code_producing?(:task)
      refute Selection.code_producing?(:epic)
    end
  end

  describe "empty / nil inputs" do
    test "no config → no skills", %{ws: ws} do
      assert Selection.resolve(task: task(ws), workspace: nil, repo: nil) == []
    end

    test "workspace struct config is read", %{ws: ws} do
      {:ok, ws} =
        Ash.update(ws, %{patch: %{"skills" => %{"workspace" => ["debug"]}}}, action: :patch_config)

      resolved = Selection.resolve(task: task(ws), workspace: ws, repo: nil)
      assert names(resolved) == ["debug"]
    end
  end
end
