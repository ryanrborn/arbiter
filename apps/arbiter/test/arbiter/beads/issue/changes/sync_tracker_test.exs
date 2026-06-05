defmodule Arbiter.Beads.Issue.Changes.SyncTrackerTest do
  @moduledoc """
  Wiring tests for Arbiter→tracker sync on bead status transitions.

  Exercises the full Ash action path (`:close` / `:reopen` / `:update`) with the
  GitHub HTTP client mocked via `Req.Test` (`:github_http_stub` is true in the
  test env). Asserts the local transition reaches out to the resolved adapter
  for tracked beads, leaves untracked beads alone, and survives a sync failure.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers.GitHub.Config

  @owner "ryanrborn"
  @repo "arbiter"
  @ref "36"
  @env_var "GTE_SYNC_TRACKER_TEST_TOKEN"

  @tracker_config %{
    "owner" => @owner,
    "repo" => @repo,
    "credentials_ref" => "env:#{@env_var}"
  }

  setup do
    System.put_env(@env_var, "test-github-token")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gh-ws-#{System.unique_integer([:positive])}",
        prefix: "gh",
        config: %{"tracker" => %{"type" => "github", "config" => @tracker_config}}
      })

    ws
  end

  defp plain_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "plain-ws-#{System.unique_integer([:positive])}",
        prefix: "pl"
      })

    ws
  end

  # Stub that forwards each request to the test process so we can assert on the
  # method + decoded body, and answers GET (current issue) / PATCH (the write).
  defp forwarding_stub do
    test_pid = self()

    Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
      case conn.method do
        "GET" ->
          send(test_pid, {:github, :get, conn.request_path})

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"number" => 36, "state" => "open", "labels" => []})

        "PATCH" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:github, :patch, conn.request_path, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"number" => 36, "state" => "closed"})
      end
    end)
  end

  describe ":close on a github-tracked bead" do
    test "PATCHes the linked issue to state=closed" do
      forwarding_stub()
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed

      expected_path = "/repos/#{@owner}/#{@repo}/issues/#{@ref}"
      assert_receive {:github, :get, ^expected_path}
      assert_receive {:github, :patch, ^expected_path, %{"state" => "closed"}}
    end
  end

  describe ":close on an untracked bead" do
    test "does NOT call the tracker adapter" do
      forwarding_stub()
      ws = plain_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "untracked",
          tracker_type: :none,
          workspace_id: ws.id
        })

      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed

      refute_receive {:github, _, _}
      refute_receive {:github, _, _, _}
    end

    test "github bead WITHOUT a tracker_ref does NOT call the adapter" do
      forwarding_stub()
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked-but-unlinked",
          tracker_type: :github,
          tracker_ref: nil,
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      assert {:ok, _closed} = Ash.update(issue, %{}, action: :close)

      refute_receive {:github, _, _}
      refute_receive {:github, _, _, _}
    end
  end

  describe "sync failure is best-effort" do
    test "a tracker error does not break the local close" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "boom"})
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked-but-tracker-down",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed
    end

    test "missing tracker config does not break the local close" do
      # No stub needed: config resolution fails before any HTTP call.
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked-misconfigured",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      System.delete_env(@env_var)

      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed
    end
  end

  describe ":reopen on a github-tracked bead" do
    test "PATCHes the linked issue back to state=open" do
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "to-reopen",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      # Close first (with a stub) so we can reopen.
      forwarding_stub()
      {:ok, closed} = Ash.update(issue, %{}, action: :close)

      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 36, "state" => "closed", "labels" => []})

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:reopen_patch, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 36, "state" => "open"})
        end
      end)

      assert {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)
      assert reopened.status == :open
      assert_receive {:reopen_patch, %{"state" => "open"}}
    end
  end

  describe ":update with an open ⇄ in_progress transition" do
    test "syncs in_progress to the tracker (open issue + in-progress label)" do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 36, "state" => "open", "labels" => []})

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:update_patch, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 36})
        end
      end)

      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "to-progress",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, updated} = Ash.update(issue, %{status: :in_progress}, action: :update)
      assert updated.status == :in_progress

      assert_receive {:update_patch, payload}
      assert payload["state"] == "open"
      assert payload["labels"] == ["in progress"]
    end

    test "a non-status :update does NOT call the adapter" do
      forwarding_stub()
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "title-edit-only",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, _updated} = Ash.update(issue, %{title: "new title"}, action: :update)

      refute_receive {:github, _, _}
      refute_receive {:github, _, _, _}
    end
  end

  describe "gated forward transition on a jira-tracked bead" do
    @jira_env "GTE_SYNC_TRACKER_JIRA_TOKEN"
    @jira_ref "VR-17585"

    defp jira_workspace do
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
                "credentials_ref" => "env:#{@jira_env}",
                "email" => "tester@example.com",
                "status_map" => %{"closed" => "Code Merged"},
                "field_ids" => %{
                  "qa_notes" => "customfield_10184",
                  "deployment_notes" => "customfield_10185"
                }
              }
            }
          }
        })

      ws
    end

    # Forwards each Jira call to the test pid; answers the field PUT and the
    # transitions GET/POST so a full push-then-transition succeeds.
    defp jira_forwarding_stub do
      test_pid = self()

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        case {conn.method, path} do
          {"PUT", _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:jira, :put_fields, path, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          {"GET", _} ->
            send(test_pid, {:jira, :get_transitions, path})

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"transitions" => [%{"id" => "31", "name" => "Code Merged"}]})

          {"POST", _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:jira, :transition, path, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)
    end

    setup do
      System.put_env(@jira_env, "test-jira-token")
      on_exit(fn -> System.delete_env(@jira_env) end)
      :ok
    end

    test "pushes QA + Deployment notes BEFORE transitioning the ticket" do
      jira_forwarding_stub()
      ws = jira_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked-with-notes",
          tracker_type: :jira,
          tracker_ref: @jira_ref,
          qa_notes: "Verify the new endpoint returns 200 for a valid token.",
          deployment_notes: "No migrations. Gated behind the `jira_sync` flag.",
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed

      # The custom fields are written first…
      fields_path = "/rest/api/3/issue/#{@jira_ref}"
      assert_receive {:jira, :put_fields, ^fields_path, %{"fields" => fields}}
      assert Map.has_key?(fields, "customfield_10184")
      assert Map.has_key?(fields, "customfield_10185")
      # …markdown is ADF-encoded.
      assert fields["customfield_10184"]["type"] == "doc"

      # …then the transition fires.
      assert_receive {:jira, :get_transitions, _}
      transitions_path = "/rest/api/3/issue/#{@jira_ref}/transitions"
      assert_receive {:jira, :transition, ^transitions_path, %{"transition" => %{"id" => "31"}}}
    end

    test "BLOCKS the transition when the gated notes are missing" do
      jira_forwarding_stub()
      ws = jira_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "tracked-without-notes",
          tracker_type: :jira,
          tracker_ref: @jira_ref,
          qa_notes: nil,
          deployment_notes: nil,
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      # Local close still succeeds (best-effort sync) …
      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed

      # … but NOTHING is pushed to Jira: no field write, no transition.
      refute_receive {:jira, :put_fields, _, _}
      refute_receive {:jira, :transition, _, _}
    end
  end

  describe "config isolation" do
    test "prepare/2 uses the bead's workspace config, not a stale process config" do
      # Seed a *different* workspace config in the process dict; the sync must
      # override it from the bead's own workspace.
      Config.put_active(%{
        "owner" => "someone-else",
        "repo" => "other-repo",
        "credentials_ref" => "env:#{@env_var}"
      })

      forwarding_stub()
      ws = github_workspace()

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "right-repo",
          tracker_type: :github,
          tracker_ref: @ref,
          workspace_id: ws.id
        })

      assert {:ok, _closed} = Ash.update(issue, %{}, action: :close)

      expected_path = "/repos/#{@owner}/#{@repo}/issues/#{@ref}"
      assert_receive {:github, :patch, ^expected_path, _}
    end
  end
end
