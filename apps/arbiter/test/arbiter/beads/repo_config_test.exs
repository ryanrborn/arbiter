defmodule Arbiter.Beads.RepoConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.Beads.RepoConfig

  describe "repo_path_from_config/1" do
    test "returns a bare string path unchanged" do
      assert RepoConfig.repo_path_from_config("/home/dev/repo") == "/home/dev/repo"
    end

    test "returns the path from an object-form entry" do
      assert RepoConfig.repo_path_from_config(%{"path" => "/srv/arbiter"}) == "/srv/arbiter"
    end

    test "returns the path from an object-form entry that also has target_branch" do
      assert RepoConfig.repo_path_from_config(%{
               "path" => "/srv/arbiter",
               "target_branch" => "integration/dolphin"
             }) == "/srv/arbiter"
    end

    test "returns nil for an empty string" do
      assert RepoConfig.repo_path_from_config("") == nil
    end

    test "returns nil for a map with an empty path" do
      assert RepoConfig.repo_path_from_config(%{"path" => ""}) == nil
    end

    test "returns nil for a map without a path key" do
      assert RepoConfig.repo_path_from_config(%{"target_branch" => "main"}) == nil
    end

    test "returns nil for nil" do
      assert RepoConfig.repo_path_from_config(nil) == nil
    end
  end

  describe "repo_target_from_config/1" do
    test "returns the target_branch from an object-form entry" do
      assert RepoConfig.repo_target_from_config(%{"target_branch" => "integration/dolphin"}) ==
               "integration/dolphin"
    end

    test "returns nil for a bare string" do
      assert RepoConfig.repo_target_from_config("/home/dev/repo") == nil
    end

    test "returns nil for a map without target_branch" do
      assert RepoConfig.repo_target_from_config(%{"path" => "/srv/arbiter"}) == nil
    end

    test "returns nil for an empty target_branch" do
      assert RepoConfig.repo_target_from_config(%{"target_branch" => ""}) == nil
    end

    test "returns nil for nil" do
      assert RepoConfig.repo_target_from_config(nil) == nil
    end
  end
end
