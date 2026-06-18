defmodule Arbiter.Trackers.SyncTest do
  @moduledoc """
  Tests for the loud, Summons-raising tracker lifecycle orchestration
  (`Arbiter.Trackers.Sync`) — the layer that drives the real VR workflow:

    * PR-open -> In Code Review + a PR-link comment + a remote link.
    * Tribunal-approved-but-parked -> Pending Merge.
    * A genuine sync failure surfaces loudly as an Admiral Summons (the
      VR-17911 silent-failure regression guard).

  Jira HTTP is stubbed via `Req.Test` (`:jira_http_stub` is true in test env).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Trackers.Sync

  @ref "VR-17585"
  @env "GTE_TRACKER_SYNC_JIRA_TOKEN"

  setup do
    System.put_env(@env, "test-jira-token")
    on_exit(fn -> System.delete_env(@env) end)
    :ok
  end

  defp jira_workspace(status_map) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "jira-ws-#{System.unique_integer([:positive])}",
        prefix: "jr",
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "leotechnologies.atlassian.net",
              "project_key" => "VR",
              "credentials_ref" => "env:#{@env}",
              "email" => "tester@example.com",
              "status_map" => status_map
            }
          }
        }
      })

    ws
  end

  defp jira_issue(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "tracked",
        tracker_type: :jira,
        tracker_ref: @ref,
        skip_upstream_create: true,
        workspace_id: ws.id
      })

    issue
  end

  defp escalations_for(ws_id) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.workspace_id == ws_id and &1.kind == :escalation))
  end

  describe "lifecycle/3 :pr_opened" do
    test "transitions to In Code Review, comments the PR URL, and adds a remote link" do
      test_pid = self()
      ws = jira_workspace(%{"pr_opened" => "In Code Review"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "51",
                  "name" => "Pull request created",
                  "to" => %{"name" => "In Code Review"}
                }
              ]
            })

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" and String.ends_with?(path, "/comment") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:comment, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "1"})

          conn.method == "POST" and String.ends_with?(path, "/remotelink") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:remotelink, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 10_001})
        end
      end)

      url = "https://github.com/leo/voice-id-core/pull/3606"

      assert :ok =
               Sync.lifecycle(issue, :pr_opened, pr_url: url, pr_title: "PR #3606 (#{issue.id})")

      # Transitioned toward "In Code Review" (single-hop via "Pull request created").
      assert_receive {:transition, %{"transition" => %{"id" => "51"}}}
      # Commented with the PR URL (ADF body).
      assert_receive {:comment, %{"body" => %{"type" => "doc"} = adf}}
      assert adf |> get_in(["content"]) |> is_list()
      # Added a remote link keyed off the PR URL (idempotent globalId).
      assert_receive {:remotelink,
                      %{"object" => %{"url" => ^url}, "globalId" => "arbiter-pr=" <> _}}

      # No spurious Summons on the happy path.
      assert escalations_for(ws.id) == []
    end
  end

  describe "lifecycle/3 :approved_unmerged" do
    test "transitions an approved-but-parked ticket to Pending Merge" do
      test_pid = self()
      ws = jira_workspace(%{"approved_unmerged" => "Pending Merge"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cond do
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "111",
                  "name" => "Approved and not merged",
                  "to" => %{"name" => "Pending Merge"}
                }
              ]
            })

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :approved_unmerged)

      assert_receive {:transition, %{"transition" => %{"id" => "111"}}}
      assert escalations_for(ws.id) == []
    end
  end

  describe "loud failure -> Admiral Summons" do
    test "an unreachable mapped status raises an escalation instead of failing silently" do
      # in_progress -> "Nowhere" is unreachable: no direct transition and no
      # graph path. This is exactly the VR-17911 silent-failure shape.
      ws = jira_workspace(%{"in_progress" => "Nowhere"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        if conn.method == "GET" and String.ends_with?(conn.request_path, "/transitions") do
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "transitions" => [
              %{"id" => "9", "name" => "noop", "to" => %{"name" => "In Code Review"}}
            ]
          })
        else
          # current-status fetch
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"fields" => %{"status" => %{"name" => "In Progress"}}})
        end
      end)

      # lifecycle/3 seeds the adapter config from the workspace, then drives
      # the transition; the loud failure surfaces as an escalation (the call
      # itself stays best-effort and returns :ok).
      assert :ok = Sync.lifecycle(issue, :in_progress)

      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
      [summons] = escalations
      assert summons.to_ref == "admiral"
      assert summons.directive_ref == issue.id
      assert summons.subject =~ "tracker sync failed"
      assert summons.body =~ "status_map"
    end

    test "a benign unmapped event is skipped without a Summons" do
      # The tracker explicitly does not model :merged (blank mapping overrides
      # the default). map_status -> :status_unmapped, which is a quiet skip.
      ws = jira_workspace(%{"in_progress" => "In Progress", "merged" => ""})
      issue = jira_issue(ws)

      # No HTTP stub needed: map_status short-circuits before any request.
      assert :ok = Sync.transition_event(issue, :merged)
      assert escalations_for(ws.id) == []
    end

    test "an untracked bead is a no-op" do
      ws = jira_workspace(%{"in_progress" => "In Progress"})

      {:ok, issue} =
        Ash.create(Issue, %{title: "untracked", tracker_type: :none, workspace_id: ws.id})

      assert :ok = Sync.lifecycle(issue, :pr_opened, pr_url: "https://x/pr/1")
      assert escalations_for(ws.id) == []
    end
  end
end
