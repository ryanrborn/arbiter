defmodule Arbiter.Tasks.Issue.Changes.ParentTrackerDefaultTest do
  @moduledoc """
  #1973: a task created under a tracker-linked parent defaults from the
  *parent's* linkage, not the workspace's tracker type — so splitting a tracked
  story into local slices no longer mints one upstream ticket per slice.

  Exercises the full `Issue.create` action (InheritTrackerType + CreateUpstream)
  against the Jira and GitHub HTTP stubs. Every "no ticket minted" case installs
  a stub that flunks on any request, so an outbound create fails the test rather
  than being silently swallowed into `CreateUpstream.last_error/0`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream
  alias Arbiter.Tasks.Workspace

  @env_var "GTE_PARENT_TRACKER_DEFAULT_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-token")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp jira_workspace(extra \\ %{}) do
    tracker =
      Map.merge(
        %{
          "type" => "jira",
          "config" => %{
            "host" => "test.atlassian.net",
            "project_key" => "VR",
            "credentials_ref" => "env:#{@env_var}",
            "email" => "tester@example.com"
          }
        },
        extra
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ptd-jira-#{System.unique_integer([:positive])}",
        prefix: "pj",
        config: %{"tracker" => tracker}
      })

    ws
  end

  defp github_workspace(extra \\ %{}) do
    tracker =
      Map.merge(
        %{
          "type" => "github",
          "config" => %{
            "owner" => "ryanrborn",
            "repo" => "arbiter",
            "credentials_ref" => "env:#{@env_var}"
          }
        },
        extra
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ptd-gh-#{System.unique_integer([:positive])}",
        prefix: "pg",
        config: %{"tracker" => tracker}
      })

    ws
  end

  defp no_upstream_calls! do
    Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn _ -> flunk("must not call Jira") end)
    Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn _ -> flunk("must not call GitHub") end)
  end

  # A parent already bound to an upstream ticket (as `tracker_claim` or
  # `--tracker-ref` leaves it) — binding never calls upstream.
  defp tracked_parent(ws, type, ref) do
    {:ok, parent} =
      Ash.create(Issue, %{
        title: "tracked story",
        workspace_id: ws.id,
        tracker_type: type,
        tracker_ref: ref
      })

    parent
  end

  defp create_child(ws, parent, attrs \\ %{}) do
    Ash.create(
      Issue,
      Map.merge(%{title: "a slice", workspace_id: ws.id, parent_id: parent.id}, attrs)
    )
  end

  describe "context_only (the default when tracker.child_policy is unset)" do
    test "a child of a Jira-tracked parent is local, carries the parent as context, mints nothing" do
      no_upstream_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} = create_child(ws, parent)

      assert child.tracker_type == :none
      assert child.tracker_ref == nil
      assert child.tracker_context_type == :jira
      assert child.tracker_context_ref == "VR-19083"
      assert CreateUpstream.last_error() == nil

      assert Ash.get!(Issue, child.id).tracker_ref == nil
    end

    test "a child of a GitHub-tracked parent is local, carries the parent as context, mints nothing" do
      no_upstream_calls!()
      ws = github_workspace()
      parent = tracked_parent(ws, :github, "1973")

      assert {:ok, child} = create_child(ws, parent)

      assert child.tracker_type == :none
      assert child.tracker_ref == nil
      assert child.tracker_context_type == :github
      assert child.tracker_context_ref == "1973"
      assert CreateUpstream.last_error() == nil
    end

    test "a grandchild of a context-only child keeps the same context and mints nothing" do
      no_upstream_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws, :jira, "VR-19083")
      {:ok, child} = create_child(ws, parent)

      assert {:ok, grandchild} = create_child(ws, child)

      assert grandchild.tracker_type == :none
      assert grandchild.tracker_context_type == :jira
      assert grandchild.tracker_context_ref == "VR-19083"
    end

    test "an explicit tracker_context_ref from the caller is kept" do
      no_upstream_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} =
               create_child(ws, parent, %{
                 tracker_context_type: :jira,
                 tracker_context_ref: "VR-20000"
               })

      assert child.tracker_type == :none
      assert child.tracker_context_ref == "VR-20000"
    end

    test "tracker.child_policy: context_only behaves the same as unset" do
      no_upstream_calls!()
      ws = jira_workspace(%{"child_policy" => "context_only"})
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} = create_child(ws, parent)
      assert child.tracker_type == :none
      assert child.tracker_context_ref == "VR-19083"
    end
  end

  describe "explicit tracker_type still wins" do
    test "an explicit workspace tracker_type mints as today" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        send(test_pid, :minted)
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 2001})
      end)

      ws = github_workspace()
      parent = tracked_parent(ws, :github, "1973")

      assert {:ok, child} = create_child(ws, parent, %{tracker_type: :github})

      assert_receive :minted
      assert child.tracker_type == :github
      assert child.tracker_ref == "2001"
      assert child.tracker_context_ref == nil
    end

    test "an explicit tracker_ref binds that ticket rather than the parent's context" do
      no_upstream_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} = create_child(ws, parent, %{tracker_ref: "VR-30000"})

      assert child.tracker_type == :jira
      assert child.tracker_ref == "VR-30000"
      assert child.tracker_context_ref == nil
    end
  end

  describe "tracker.child_policy" do
    test "mint keeps today's behavior: the child mints its own ticket" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        send(test_pid, :minted)
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 2002})
      end)

      ws = github_workspace(%{"child_policy" => "mint"})
      parent = tracked_parent(ws, :github, "1973")

      assert {:ok, child} = create_child(ws, parent)

      assert_receive :minted
      assert child.tracker_type == :github
      assert child.tracker_ref == "2002"
      assert child.tracker_context_ref == nil
    end

    test "inherit_parent links the child to the parent's own ticket and mints nothing" do
      no_upstream_calls!()
      ws = jira_workspace(%{"child_policy" => "inherit_parent"})
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} = create_child(ws, parent)

      assert child.tracker_type == :jira
      assert child.tracker_ref == "VR-19083"
      assert child.tracker_context_ref == nil
      assert CreateUpstream.last_error() == nil
    end

    test "inherit_parent under a context-only parent falls back to its context" do
      no_upstream_calls!()
      ws = jira_workspace(%{"child_policy" => "inherit_parent"})

      {:ok, parent} =
        Ash.create(Issue, %{
          title: "context-only parent",
          workspace_id: ws.id,
          tracker_type: :none,
          tracker_context_type: :jira,
          tracker_context_ref: "VR-19083"
        })

      assert {:ok, child} = create_child(ws, parent)

      assert child.tracker_type == :none
      assert child.tracker_ref == nil
      assert child.tracker_context_ref == "VR-19083"
    end

    test "the tracker_child_policy argument overrides the workspace policy" do
      no_upstream_calls!()
      ws = jira_workspace(%{"child_policy" => "mint"})
      parent = tracked_parent(ws, :jira, "VR-19083")

      assert {:ok, child} = create_child(ws, parent, %{tracker_child_policy: :context_only})

      assert child.tracker_type == :none
      assert child.tracker_context_ref == "VR-19083"
    end
  end

  describe "unchanged paths" do
    test "a create with no parent_id still inherits the workspace tracker and mints" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        send(test_pid, :minted)
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 2003})
      end)

      ws = github_workspace()

      assert {:ok, issue} = Ash.create(Issue, %{title: "top level", workspace_id: ws.id})

      assert_receive :minted
      assert issue.tracker_type == :github
      assert issue.tracker_ref == "2003"
      assert issue.tracker_context_ref == nil
    end

    test "a child of an untracked parent inherits the workspace tracker as before" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        send(test_pid, :minted)
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 2004})
      end)

      ws = github_workspace()

      {:ok, parent} =
        Ash.create(Issue, %{title: "local parent", workspace_id: ws.id, tracker_type: :none})

      assert {:ok, child} = create_child(ws, parent)

      assert_receive :minted
      assert child.tracker_type == :github
      assert child.tracker_ref == "2004"
    end

    test "an unknown parent_id falls back to the workspace default" do
      no_upstream_calls!()
      ws = jira_workspace()

      assert {:ok, child} =
               Ash.create(Issue, %{
                 title: "orphan",
                 workspace_id: ws.id,
                 parent_id: "pj-nope",
                 skip_upstream_create: true
               })

      assert child.tracker_type == :jira
      assert child.tracker_context_ref == nil
    end
  end
end
