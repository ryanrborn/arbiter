defmodule Arbiter.MCP.TaskCreateTrackedParentTest do
  @moduledoc """
  #1973 through `task_create`: the refine split of `VR-19083` minted
  `VR-19092..94` because the child create never told `Issue.create` who its
  parent was. Covers the coordinator path (parent-aware default, explicit
  `tracker_type` still mints) and the refine path (always context-only, even
  under a workspace that chose `tracker.child_policy: mint`).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @env_var "GTE_TASK_CREATE_TRACKED_PARENT_TOKEN"

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
        name: "tctp-#{System.unique_integer([:positive])}",
        prefix: "lt",
        config: %{"tracker" => tracker}
      })

    ws
  end

  defp tracked_parent(ws) do
    {:ok, parent} =
      Ash.create(Issue, %{
        title: "VR-19083 story",
        workspace_id: ws.id,
        tracker_type: :jira,
        tracker_ref: "VR-19083",
        acceptance: "- ac"
      })

    parent
  end

  defp coordinator(ws), do: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

  defp refine(ws, parent),
    do: %Scope{tier: :refine, workspace_id: ws.id, issue_id: parent.id, session_id: "sess-1973"}

  defp no_jira_calls!,
    do: Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn _ -> flunk("must not call Jira") end)

  defp child_ids(parent), do: Enum.map(Dependencies.for_issue(parent.id).children, & &1.issue_id)

  describe "coordinator task_create with parent_id" do
    test "a child of a Jira-tracked parent is context-only and mints nothing" do
      no_jira_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws)

      assert {:ok, %{id: id, parent_id: parent_id}} =
               Catalog.call(coordinator(ws), "task_create", %{
                 "title" => "slice one",
                 "parent_id" => parent.id
               })

      assert parent_id == parent.id
      child = Ash.get!(Issue, id)
      assert child.tracker_type == :none
      assert child.tracker_ref == nil
      assert child.tracker_context_type == :jira
      assert child.tracker_context_ref == "VR-19083"
      assert id in child_ids(parent)
    end

    test "an explicit tracker_type still mints" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        send(test_pid, {:jira, conn.method, conn.request_path})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "10001", "key" => "VR-19092"})
      end)

      ws = jira_workspace()
      parent = tracked_parent(ws)

      assert {:ok, %{id: id}} =
               Catalog.call(coordinator(ws), "task_create", %{
                 "title" => "slice minted on purpose",
                 "parent_id" => parent.id,
                 "tracker_type" => "jira"
               })

      assert_receive {:jira, "POST", _path}
      child = Ash.get!(Issue, id)
      assert child.tracker_type == :jira
      assert child.tracker_ref == "VR-19092"
      assert child.tracker_context_ref == nil
    end
  end

  describe "refine task_create" do
    test "children of the bound tracked issue are context-only and mint nothing" do
      no_jira_calls!()
      ws = jira_workspace()
      parent = tracked_parent(ws)

      ids =
        for title <- ["slice a", "slice b", "slice c"] do
          assert {:ok, %{id: id}} =
                   Catalog.call(refine(ws, parent), "task_create", %{"title" => title})

          id
        end

      for id <- ids do
        child = Ash.get!(Issue, id)
        assert child.tracker_type == :none
        assert child.tracker_ref == nil
        assert child.tracker_context_ref == "VR-19083"
        assert id in child_ids(parent)
      end
    end

    test "stay context-only even when the workspace policy is mint" do
      no_jira_calls!()
      ws = jira_workspace(%{"child_policy" => "mint"})
      parent = tracked_parent(ws)

      assert {:ok, %{id: id}} =
               Catalog.call(refine(ws, parent), "task_create", %{"title" => "refined slice"})

      child = Ash.get!(Issue, id)
      assert child.tracker_type == :none
      assert child.tracker_context_ref == "VR-19083"
    end
  end
end
