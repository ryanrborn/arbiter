defmodule Arbiter.Polecat.TargetBranchTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat.TargetBranch

  defp workspace(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "tb-#{System.unique_integer([:positive])}",
        prefix: "tb#{System.unique_integer([:positive])}",
        config: config
      })

    ws
  end

  defp bead(ws, attrs \\ %{}) do
    {:ok, bead} =
      Ash.create(Issue, Map.merge(%{title: "b", workspace_id: ws.id}, attrs))

    bead
  end

  describe "resolve/2 precedence chain" do
    test "explicit :base_branch override wins over everything" do
      ws = workspace(%{"repo_paths" => %{"r" => %{"target_branch" => "rigbr"}}})
      b = bead(ws, %{target_branch: "beadbr"})

      assert "override" =
               TargetBranch.resolve(b, base_branch: "override", repo: "r", workspace_base: "ws")
    end

    test "per-bead target_branch beats repo, workspace_base and merge.base" do
      ws =
        workspace(%{
          "repo_paths" => %{"r" => %{"target_branch" => "rigbr"}},
          "merge" => %{"base" => "mergebr"}
        })

      b = bead(ws, %{target_branch: "beadbr"})

      assert "beadbr" = TargetBranch.resolve(b, repo: "r", workspace_base: "queuebr")
    end

    test "per-repo target_branch applies when the bead has none" do
      ws =
        workspace(%{
          "repo_paths" => %{"r" => %{"path" => "/tmp", "target_branch" => "rigbr"}},
          "merge" => %{"base" => "mergebr"}
        })

      b = bead(ws)

      # Repo beats the workspace merge.base and the queue-level base.
      assert "rigbr" = TargetBranch.resolve(b, repo: "r", workspace_base: "queuebr")
    end

    test "string-form repo_paths entry has no target_branch; falls through" do
      ws =
        workspace(%{"repo_paths" => %{"r" => "/just/a/path"}, "merge" => %{"base" => "mergebr"}})

      b = bead(ws)

      assert "mergebr" = TargetBranch.resolve(b, repo: "r")
    end

    test "queue-level :workspace_base beats merge.base but loses to bead/repo" do
      ws = workspace(%{"merge" => %{"base" => "mergebr"}})
      b = bead(ws)

      assert "queuebr" = TargetBranch.resolve(b, workspace_base: "queuebr")
    end

    test "falls back to workspace merge.base when nothing more specific is set" do
      ws = workspace(%{"merge" => %{"base" => "development"}})
      b = bead(ws)

      assert "development" = TargetBranch.resolve(b, repo: "r")
    end

    test "defaults to main for a bare workspace with no overrides" do
      ws = workspace(%{})
      b = bead(ws)

      assert "main" = TargetBranch.resolve(b)
      assert "main" = TargetBranch.resolve(b, repo: "r", workspace_base: nil)
    end

    test "nil repo means the per-repo default never applies" do
      ws = workspace(%{"repo_paths" => %{"r" => %{"target_branch" => "rigbr"}}})
      b = bead(ws)

      assert "main" = TargetBranch.resolve(b, repo: nil)
    end
  end
end
