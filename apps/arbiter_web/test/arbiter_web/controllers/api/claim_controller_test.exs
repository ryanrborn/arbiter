defmodule ArbiterWeb.Api.ClaimControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config
  alias Arbiter.Trackers.Jira.Config, as: JiraConfig

  @viewer "ctrl-acolyte"
  @jira_account_id "ctrl-jira-account"
  @env_var "ARBITER_CLAIM_CTRL_TOKEN"

  setup %{conn: conn} do
    System.put_env(@env_var, "ctrl-test-token")

    {:ok, github_ws} =
      Ash.create(Workspace, %{
        name: "claim-ctrl-gh",
        prefix: "cctl",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    {:ok, jira_ws} =
      Ash.create(Workspace, %{
        name: "claim-ctrl-jira",
        prefix: "ccj",
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "test.atlassian.net",
              "project_key" => "TEST",
              "credentials_ref" => "env:#{@env_var}",
              "email" => "tester@example.com"
            }
          }
        }
      })

    {:ok, none_ws} = Ash.create(Workspace, %{name: "claim-ctrl-none", prefix: "ccno"})

    on_exit(fn ->
      Config.clear()
      JiraConfig.clear()
      System.delete_env(@env_var)
    end)

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     gh: github_ws,
     jira: jira_ws,
     none: none_ws}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)
  defp stub_jira(fun), do: Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fun)

  defp jira_issue_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "TEST-43",
        "fields" => %{
          "summary" => "Wire up the Jira thing",
          "description" => nil,
          "assignee" => %{"accountId" => @jira_account_id},
          "status" => %{
            "name" => "To Do",
            "statusCategory" => %{"key" => "new"}
          }
        }
      },
      overrides
    )
  end

  defp issue_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 43,
        "title" => "Wire up the thing",
        "body" => "Mirror me into a task.",
        "state" => "open",
        "html_url" => "https://github.com/ryanrborn/arbiter/issues/43",
        "assignees" => [%{"login" => @viewer}]
      },
      overrides
    )
  end

  describe "POST /api/workspaces/:workspace_id/claim" do
    test "creates a task linked to #43 when assigned to viewer", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      body = json_response(conn, 201)
      assert body["status"] == "created"
      assert body["task"]["tracker_type"] == "github"
      assert body["task"]["tracker_ref"] == "43"
      assert body["task"]["title"] == "Wire up the thing"
    end

    test "200 when task already exists (idempotent)", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      conn1 = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      assert json_response(conn1, 201)

      conn2 = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      body = json_response(conn2, 200)
      assert body["status"] == "existing"
    end

    test "403 when issue isn't assigned to the viewer", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", _} ->
            Req.Test.json(conn, issue_payload(%{"assignees" => [%{"login" => "other"}]}))
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      assert %{"error" => %{"type" => "not_assigned"}} = json_response(conn, 403)
    end

    test "force=true bypasses the assignment check", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", _} ->
            Req.Test.json(conn, issue_payload(%{"assignees" => []}))

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43", "force" => true})
      assert json_response(conn, 201)
    end

    test "400 when ref is missing", %{conn: conn, gh: ws} do
      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "400 when workspace has no claim-capable tracker", %{conn: conn, none: ws} do
      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "claims a Jira issue through the workspace's Jira adapter", %{conn: conn, jira: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            Req.Test.json(conn, jira_issue_payload())
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "TEST-43"})
      body = json_response(conn, 201)
      assert body["status"] == "created"
      assert body["task"]["tracker_type"] == "jira"
      assert body["task"]["tracker_ref"] == "TEST-43"
      assert body["task"]["title"] == "Wire up the Jira thing"
    end

    test "renders a Jira tracker error with the mapped HTTP status", %{conn: conn, jira: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-99"} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"errorMessages" => ["not found"]})
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "TEST-99"})

      assert %{"error" => %{"type" => "tracker_error", "details" => %{"kind" => "not_found"}}} =
               json_response(conn, 404)
    end
  end

  describe "GET /api/workspaces/:workspace_id/sync/plan" do
    test "returns the plan without acting", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [issue_payload(%{"number" => 43, "title" => "Issue 43"})])
        end
      end)

      conn = get(conn, ~p"/api/workspaces/#{ws.id}/sync/plan")
      body = json_response(conn, 200)
      assert [%{"action" => "create", "ref" => "43"}] = body["data"]

      # And no task was actually created.
      tasks = Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id))
      assert tasks == []
    end

    test "empty plan when tracker is none", %{conn: conn, none: ws} do
      conn = get(conn, ~p"/api/workspaces/#{ws.id}/sync/plan")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/workspaces/:workspace_id/sync" do
    test "applies the plan (creates the assigned task)", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [issue_payload(%{"number" => 43, "title" => "Issue 43"})])

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 43, "title" => "Issue 43"}))

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/sync", %{})
      body = json_response(conn, 200)
      assert body["applied"] == true
      assert [%{"outcome" => "created"}] = body["results"]
    end
  end
end
