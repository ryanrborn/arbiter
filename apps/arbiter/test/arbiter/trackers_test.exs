defmodule Arbiter.TrackersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Trackers.{GitHub, Jira, Linear, None, Shortcut}

  describe "for_task/1 and for_type/1" do
    test "returns Tracker.None for :none-typed issues" do
      issue = %Issue{tracker_type: :none, tracker_ref: nil}
      assert Trackers.for_task(issue) == None
    end

    test "for_type/1 returns Tracker.None for :none" do
      assert Trackers.for_type(:none) == None
    end

    test "for_type/1 returns Tracker.Jira for :jira (wired in gte-029)" do
      assert Trackers.for_type(:jira) == Jira
    end

    test "for_type/1 returns Tracker.Shortcut for :shortcut" do
      assert Trackers.for_type(:shortcut) == Shortcut
    end

    test "for_type/1 returns Tracker.Linear for :linear (wired in Phase 5)" do
      assert Trackers.for_type(:linear) == Linear
    end

    test "for_type/1 raises ArgumentError for truly unregistered types" do
      assert_raise ArgumentError, ~r/no tracker adapter registered for :unknown_tracker/, fn ->
        Trackers.for_type(:unknown_tracker)
      end
    end

    test "adapters/0 exposes the registered map" do
      assert Trackers.adapters() ==
               %{none: None, jira: Jira, shortcut: Shortcut, github: GitHub, linear: Linear}
    end
  end

  describe "for_workspace/1 — adapter resolution with loud-warn fallback" do
    defp linear_workspace do
      %Workspace{
        id: "ws-test-linear",
        name: "test-workspace",
        prefix: "bd",
        config: %{"tracker" => %{"type" => "linear"}}
      }
    end

    defp none_workspace do
      %Workspace{
        id: "ws-test-none",
        name: "none-workspace",
        prefix: "bd",
        config: %{"tracker" => %{"type" => "none"}}
      }
    end

    test "returns None for a workspace configured with :none (intentional — no warning)" do
      log =
        capture_log(fn ->
          assert Trackers.for_workspace(none_workspace()) == None
        end)

      refute log =~ "tracker_type"
      refute log =~ "no adapter is registered"
    end

    test "returns Linear adapter for a :linear-configured workspace without warning" do
      log =
        capture_log([level: :warning], fn ->
          assert Trackers.for_workspace(linear_workspace()) == Linear
        end)

      refute log =~ "no adapter is registered"
    end

    test "returns None silently for unknown string tracker types (atom does not exist)" do
      # A type string like "notarealtracker" cannot be converted to an existing
      # atom (no module or code references it), so workspace_tracker_type/1
      # falls back to :none via the ArgumentError rescue — no warning is emitted.
      workspace = %Workspace{
        id: "ws-test-unknown",
        name: "test-workspace",
        prefix: "bd",
        config: %{"tracker" => %{"type" => "notarealtracker"}}
      }

      log = capture_log(fn -> assert Trackers.for_workspace(workspace) == None end)
      refute log =~ "no adapter is registered"
    end

    test "returns GitHub adapter for a :github-configured workspace without warning" do
      workspace = %Workspace{
        id: "ws-github",
        name: "gh-workspace",
        prefix: "bd",
        config: %{"tracker" => %{"type" => "github"}}
      }

      log = capture_log(fn -> assert Trackers.for_workspace(workspace) == GitHub end)
      refute log =~ "no adapter is registered"
    end
  end

  describe "delegating wrappers (against Tracker.None)" do
    setup do
      {:ok, issue: %Issue{tracker_type: :none, tracker_ref: "anything"}}
    end

    test("fetch/1 delegates", %{issue: i}, do: assert(Trackers.fetch(i) == {:ok, %{}}))

    test("transition/2 delegates", %{issue: i},
      do: assert(Trackers.transition(i, :closed) == :ok)
    )

    test("update_fields/2 delegates", %{issue: i},
      do: assert(Trackers.update_fields(i, %{title: "x"}) == :ok)
    )

    test("link_for/1 delegates", %{issue: i}, do: assert(Trackers.link_for(i) == ""))

    test "list_transitions/1 delegates", %{issue: i} do
      assert {:ok, statuses} = Trackers.list_transitions(i)
      assert :closed in statuses
    end
  end
end
