defmodule Arbiter.Mergers.Github.RepoResolverTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.Github.{Error, RepoResolver}

  describe "parse/1" do
    test "parses an SSH remote with .git suffix" do
      assert {:ok, {"leo-technologies-llc", "verus_server"}} =
               RepoResolver.parse("git@github.com:leo-technologies-llc/verus_server.git")
    end

    test "parses an SSH remote without .git suffix" do
      assert {:ok, {"octo", "widget"}} =
               RepoResolver.parse("git@github.com:octo/widget")
    end

    test "parses an HTTPS remote with .git suffix" do
      assert {:ok, {"leo-technologies-llc", "verus-client"}} =
               RepoResolver.parse("https://github.com/leo-technologies-llc/verus-client.git")
    end

    test "parses an HTTPS remote without .git suffix" do
      assert {:ok, {"ryanrborn", "arbiter"}} =
               RepoResolver.parse("https://github.com/ryanrborn/arbiter")
    end

    test "parses an HTTPS remote with trailing slash" do
      assert {:ok, {"ryanrborn", "arbiter"}} =
               RepoResolver.parse("https://github.com/ryanrborn/arbiter/")
    end

    test "tolerates Enterprise GitHub hosts" do
      assert {:ok, {"leo", "verus_server"}} =
               RepoResolver.parse("git@github.example.com:leo/verus_server.git")

      assert {:ok, {"leo", "verus_server"}} =
               RepoResolver.parse("https://github.example.com/leo/verus_server.git")
    end

    test "rejects garbage" do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("not a url")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.parse("https://github.com/")

      assert {:error, %Error{kind: :config_missing}} =
               RepoResolver.parse("https://github.com/only-one-segment")
    end
  end

  describe "from_remote/1" do
    setup do
      # A local bare git repo with a configured `origin` remote is the
      # simplest way to exercise `git remote get-url origin` without hitting
      # the network. We create one in a tmp dir per test.
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "arbiter_repo_resolver_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)

      {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch=main", path])

      on_exit(fn -> File.rm_rf!(path) end)

      {:ok, path: path}
    end

    test "reads {owner, repo} from origin", %{path: path} do
      {_, 0} =
        System.cmd("git", [
          "-C",
          path,
          "remote",
          "add",
          "origin",
          "git@github.com:leo-technologies-llc/verus_server.git"
        ])

      assert {:ok, {"leo-technologies-llc", "verus_server"}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error when origin is missing", %{path: path} do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error when path is not a git checkout" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "arbiter_no_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(path)
    end

    test "returns a config_missing error for empty / nil repo_path" do
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote("")
      assert {:error, %Error{kind: :config_missing}} = RepoResolver.from_remote(nil)
    end
  end
end
