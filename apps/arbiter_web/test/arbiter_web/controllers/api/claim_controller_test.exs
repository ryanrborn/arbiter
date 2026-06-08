defmodule ArbiterWeb.Api.ClaimControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config

  @viewer "ctrl-acolyte"
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

    {:ok, none_ws} = Ash.create(Workspace, %{name: "claim-ctrl-none", prefix: "ccno"})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), gh: github_ws, none: none_ws}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

  defp issue_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 43,
        "title" => "Wire up the thing",
        "body" => "Mirror me into a bead.",
        "state" => "open",
        "html_url" => "https://github.com/ryanrborn/arbiter/issues/43",
        "assignees" => [%{"login" => @viewer}]
      },
      overrides
    )
  end

  describe "POST /api/workspaces/:workspace_id/claim" do
    test "creates a bead linked to #43 when assigned to viewer", %{conn: conn, gh: ws} do
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
      assert body["bead"]["tracker_type"] == "github"
      assert body["bead"]["tracker_ref"] == "43"
      assert body["bead"]["title"] == "Wire up the thing"
    end

    test "200 when bead already exists (idempotent)", %{conn: conn, gh: ws} do
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

    test "400 when workspace tracker isn't github", %{conn: conn, none: ws} do
      conn = post(conn, ~p"/api/workspaces/#{ws.id}/claim", %{"ref" => "43"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
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

      # And no bead was actually created.
      beads = Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id))
      assert beads == []
    end

    test "empty plan when tracker is none", %{conn: conn, none: ws} do
      conn = get(conn, ~p"/api/workspaces/#{ws.id}/sync/plan")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/workspaces/:workspace_id/sync" do
    test "applies the plan (creates the assigned bead)", %{conn: conn, gh: ws} do
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
