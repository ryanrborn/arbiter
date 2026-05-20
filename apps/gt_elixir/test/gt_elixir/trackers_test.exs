defmodule GtElixir.TrackersTest do
  use ExUnit.Case, async: true

  alias GtElixir.Beads.Issue
  alias GtElixir.Trackers
  alias GtElixir.Trackers.{Jira, None}

  describe "for_bead/1 and for_type/1" do
    test "returns Tracker.None for :none-typed issues" do
      issue = %Issue{tracker_type: :none, tracker_ref: nil}
      assert Trackers.for_bead(issue) == None
    end

    test "for_type/1 returns Tracker.None for :none" do
      assert Trackers.for_type(:none) == None
    end

    test "for_type/1 returns Tracker.Jira for :jira (wired in gte-029)" do
      assert Trackers.for_type(:jira) == Jira
    end

    test "for_type/1 raises ArgumentError for unregistered types (e.g. :linear pre-Phase-5)" do
      assert_raise ArgumentError, ~r/no tracker adapter registered for :linear/, fn ->
        Trackers.for_type(:linear)
      end
    end

    test "adapters/0 exposes the registered map" do
      assert Trackers.adapters() == %{none: None, jira: Jira}
    end
  end

  describe "delegating wrappers (against Tracker.None)" do
    setup do
      {:ok,
       issue: %Issue{tracker_type: :none, tracker_ref: "anything"}}
    end

    test "fetch/1 delegates", %{issue: i}, do: assert(Trackers.fetch(i) == {:ok, %{}})

    test "transition/2 delegates", %{issue: i},
      do: assert(Trackers.transition(i, :closed) == :ok)

    test "update_fields/2 delegates", %{issue: i},
      do: assert(Trackers.update_fields(i, %{title: "x"}) == :ok)

    test "link_for/1 delegates", %{issue: i}, do: assert(Trackers.link_for(i) == "")

    test "list_transitions/1 delegates", %{issue: i} do
      assert {:ok, statuses} = Trackers.list_transitions(i)
      assert :closed in statuses
    end
  end
end
