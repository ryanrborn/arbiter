defmodule Arbiter.Tasks.RepoConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.RepoConfig

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

  describe "find_path/2" do
    test "returns the path for an exact key match" do
      map = %{"widget" => "/home/dev/widget"}
      assert RepoConfig.find_path(map, "widget") == "/home/dev/widget"
    end

    test "resolves object-form entries too" do
      map = %{"widget" => %{"path" => "/home/dev/widget", "target_branch" => "main"}}
      assert RepoConfig.find_path(map, "widget") == "/home/dev/widget"
    end

    test "falls back to a normalized (underscore/hyphen-insensitive) match" do
      map = %{"verus_server" => "/home/dev/verus_server"}
      assert RepoConfig.find_path(map, "verus-server") == "/home/dev/verus_server"
    end

    test "returns nil when the repo isn't registered" do
      assert RepoConfig.find_path(%{"widget" => "/home/dev/widget"}, "other") == nil
    end

    test "returns nil for a non-map" do
      assert RepoConfig.find_path(nil, "widget") == nil
    end
  end
end
