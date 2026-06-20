defmodule Arbiter.Worker.BranchNamerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker.BranchNamer

  defp issue(opts) do
    struct(
      Issue,
      Keyword.merge(
        [
          id: "gte-010",
          title: "Default title",
          issue_type: :task,
          tracker_type: :none,
          tracker_ref: nil
        ],
        opts
      )
    )
  end

  describe "derive/1 prefix mapping" do
    test ":bug maps to bugfix/" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :bug, tracker_ref: "VR-17585", title: "Fix login bug")
        )

      assert String.starts_with?(branch, "bugfix/VR-17585-")
    end

    test ":feature maps to feature/" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :feature, tracker_ref: "VR-17585", title: "Add new flow")
        )

      assert String.starts_with?(branch, "feature/VR-17585-")
    end

    test ":task maps to feature/" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :task, tracker_ref: "VR-17585", title: "Refactor module")
        )

      assert String.starts_with?(branch, "feature/VR-17585-")
    end

    test ":epic maps to epic/" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :epic, tracker_ref: "VR-17000", title: "Migrate to Elixir")
        )

      assert String.starts_with?(branch, "epic/VR-17000-")
    end

    test ":chore maps to chore/" do
      branch =
        BranchNamer.derive(issue(issue_type: :chore, tracker_ref: "VR-99999", title: "Bump deps"))

      assert String.starts_with?(branch, "chore/VR-99999-")
    end

    test ":decision maps to chore/" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :decision, tracker_ref: "VR-99998", title: "Choose database")
        )

      assert String.starts_with?(branch, "chore/VR-99998-")
    end
  end

  describe "derive/1 ref segment" do
    test "uses tracker_ref when present" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :feature, tracker_ref: "VR-17585", title: "Add controller tests")
        )

      assert branch == "feature/VR-17585-add-controller-tests"
    end

    test "falls back to issue.id when tracker_ref is nil" do
      branch =
        BranchNamer.derive(
          issue(
            id: "gte-010",
            issue_type: :feature,
            tracker_ref: nil,
            title: "Branch namer module"
          )
        )

      assert branch == "feature/gte-010-branch-namer-module"
    end

    test "falls back to issue.id when tracker_ref is empty string" do
      branch =
        BranchNamer.derive(
          issue(
            id: "gte-010",
            issue_type: :feature,
            tracker_ref: "",
            title: "Branch namer module"
          )
        )

      assert branch == "feature/gte-010-branch-namer-module"
    end
  end

  describe "derive/1 slug derivation" do
    test "lowercases mixed-case titles" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :feature, tracker_ref: "VR-1", title: "Add Monitor Controller Tests")
        )

      assert branch == "feature/VR-1-add-monitor-controller-tests"
    end

    test "drops articles" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :feature, tracker_ref: "VR-2", title: "Add the foo bar")
        )

      assert branch == "feature/VR-2-add-foo-bar"
    end

    test "caps slug at 6 words" do
      branch =
        BranchNamer.derive(
          issue(
            issue_type: :feature,
            tracker_ref: "VR-3",
            title: "alpha beta gamma delta epsilon zeta eta theta iota"
          )
        )

      assert branch == "feature/VR-3-alpha-beta-gamma-delta-epsilon-zeta"
    end

    test "title of only stopwords becomes 'untitled'" do
      branch =
        BranchNamer.derive(
          issue(issue_type: :feature, tracker_ref: "VR-4", title: "the a an of to")
        )

      assert branch == "feature/VR-4-untitled"
    end

    test "strips emoji and non-ASCII punctuation" do
      branch =
        BranchNamer.derive(
          issue(
            issue_type: :feature,
            tracker_ref: "VR-5",
            title: "Add  rocket-launch feature!"
          )
        )

      assert branch == "feature/VR-5-add-rocket-launch-feature"
    end

    test "drops non-article stopwords too (and, or, with)" do
      branch =
        BranchNamer.derive(
          issue(
            issue_type: :feature,
            tracker_ref: "VR-6",
            title: "Sync issues with Jira and Linear"
          )
        )

      assert branch == "feature/VR-6-sync-issues-jira-linear"
    end
  end

  describe "derive/1 length cap" do
    test "truncates total length to 60 chars" do
      long_word = String.duplicate("a", 100)

      branch =
        BranchNamer.derive(issue(issue_type: :feature, tracker_ref: "VR-7", title: long_word))

      assert String.length(branch) <= 60
      assert String.starts_with?(branch, "feature/VR-7-")
    end
  end

  describe "derive/1 error cases" do
    test "raises on non-Issue input" do
      assert_raise ArgumentError, fn -> BranchNamer.derive(%{title: "x", issue_type: :task}) end
    end

    test "raises on unknown issue_type" do
      bad = issue(issue_type: :unknown, tracker_ref: "VR-1", title: "Foo")
      assert_raise ArgumentError, fn -> BranchNamer.derive(bad) end
    end
  end
end
