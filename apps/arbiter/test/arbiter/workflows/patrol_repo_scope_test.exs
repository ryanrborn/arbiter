defmodule Arbiter.Workflows.PatrolRepoScopeTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.PatrolRepoScope

  describe "repo_of_ref/1" do
    test "extracts owner/repo from a qualified GitHub ref" do
      assert PatrolRepoScope.repo_of_ref("octo/widget#42") == {:ok, "octo/widget"}
    end

    test "strips a leading github: prefix" do
      assert PatrolRepoScope.repo_of_ref("github:leo-technologies-llc/verus_server#7") ==
               {:ok, "leo-technologies-llc/verus_server"}
    end

    test "treats a bare GitHub ref as :bare" do
      assert PatrolRepoScope.repo_of_ref("#42") == :bare
    end

    test "treats a bare number as :bare" do
      assert PatrolRepoScope.repo_of_ref("42") == :bare
    end

    test "treats a GitLab !iid ref as :bare" do
      assert PatrolRepoScope.repo_of_ref("!5") == :bare
    end

    test "a three-segment path is not a valid owner/repo slug" do
      assert PatrolRepoScope.repo_of_ref("a/b/c#1") == :bare
    end
  end

  describe "ref_matches_repo?/2" do
    test "a qualified ref matches only its own repo" do
      assert PatrolRepoScope.ref_matches_repo?("octo/widget#42", "octo/widget")
      refute PatrolRepoScope.ref_matches_repo?("octo/widget#42", "octo/other")
    end

    test "a bare ref matches any repo (single-repo workspace fallback)" do
      assert PatrolRepoScope.ref_matches_repo?("#42", "octo/widget")
      assert PatrolRepoScope.ref_matches_repo?("!5", "group/project")
    end

    test "nil / non-binary inputs never match" do
      refute PatrolRepoScope.ref_matches_repo?(nil, "octo/widget")
      refute PatrolRepoScope.ref_matches_repo?("octo/widget#42", nil)
    end
  end
end
