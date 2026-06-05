defmodule Arbiter.MergersTest do
  use ExUnit.Case, async: false

  alias Arbiter.Beads.Workspace
  alias Arbiter.Mergers

  @github_env "GTE_MERGERS_PREPARE_GITHUB_TOKEN"
  @gitlab_env "GTE_MERGERS_PREPARE_GITLAB_TOKEN"

  setup do
    System.put_env(@github_env, "test-gh-prepare-token")
    System.put_env(@gitlab_env, "test-gl-prepare-token")

    on_exit(fn ->
      Mergers.Github.Config.clear()
      Mergers.Gitlab.Config.clear()
      System.delete_env(@github_env)
      System.delete_env(@gitlab_env)
    end)

    :ok
  end

  describe "for_workspace/1" do
    test "resolves :github strategy to Github adapter" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "github"}}}
      assert Mergers.for_workspace(ws) == Mergers.Github
    end

    test "resolves :gitlab strategy to Gitlab adapter" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "gitlab"}}}
      assert Mergers.for_workspace(ws) == Mergers.Gitlab
    end

    test "falls back to Direct when strategy is unset" do
      ws = %Workspace{config: %{}}
      assert Mergers.for_workspace(ws) == Mergers.Direct
    end
  end

  describe "prepare/1" do
    test "is a no-op for a nil workspace" do
      assert Mergers.prepare(nil) == :ok
    end

    test "seeds Github.Config without owner/repo — per-rig derivation shape (bd-a53kv2)" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "credentials_ref" => "env:#{@github_env}"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Github.Config.resolve()
      assert cfg.owner == nil
      assert cfg.repo == nil
      assert cfg.token == "test-gh-prepare-token"
    end

    test "seeds Github.Config from a :github-strategy workspace (bd-a1qqne regression)" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@github_env}",
              "default_target_branch" => "main"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Github.Config.resolve()
      assert cfg.owner == "ryanrborn"
      assert cfg.repo == "arbiter"
      assert cfg.token == "test-gh-prepare-token"
      assert cfg.default_target_branch == "main"
    end

    test "seeds Gitlab.Config from a :gitlab-strategy workspace" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.example.com",
              "project_id" => "42",
              "credentials_ref" => "env:#{@gitlab_env}"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Gitlab.Config.resolve()
      assert cfg.token == "test-gl-prepare-token"
    end

    test "is a no-op for a :direct-strategy workspace (no per-process config)" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "direct"}}}
      assert Mergers.prepare(ws) == :ok

      # No github/gitlab config seeded.
      assert Mergers.Github.Config.active_repo_slug() == nil
    end
  end
end
