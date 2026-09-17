defmodule ArbiterWeb.Api.TrackerControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.GitHub.Config

  @viewer "tracker-worker"
  @env_var "ARBITER_TRACKER_CTRL_TOKEN"

  setup %{conn: conn} do
    System.put_env(@env_var, "tracker-test-token")

    {:ok, github_ws} =
      Ash.create(Workspace, %{
        name: "tracker-ctrl-gh",
        prefix: "tctl",
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

    {:ok, none_ws} = Ash.create(Workspace, %{name: "tracker-ctrl-none", prefix: "tcno"})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), gh: github_ws, none: none_ws}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

  describe "GET /api/workspaces/:workspace_id/tracker/issues" do
    test "returns normalized issue summaries for a GitHub-configured workspace", %{
      conn: conn,
      gh: ws
    } do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [
              %{
                "number" => 42,
                "title" => "First",
                "state" => "open",
                "html_url" => "https://github.com/ryanrborn/arbiter/issues/42",
                "assignees" => [%{"login" => @viewer}]
              }
            ])
        end
      end)

      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      body = json_response(conn, 200)
      assert body["supported"] == true
      assert [item] = body["data"]
      assert item["ref"] == "42"
      assert item["title"] == "First"
      assert item["status"] == "open"
      assert item["url"] == "https://github.com/ryanrborn/arbiter/issues/42"
      assert item["assignees"] == [@viewer]
    end

    test "returns supported=false with empty data when tracker is none", %{conn: conn, none: ws} do
      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      body = json_response(conn, 200)
      assert body["supported"] == false
      assert body["data"] == []
    end

    test "401 from tracker is surfaced as a tracker_error envelope", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"message" => "Bad credentials"})
        end
      end)

      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      assert %{"error" => %{"type" => "tracker_error"}} = json_response(conn, 401)
    end
  end

  describe "POST /api/workspaces/:workspace_id/tracker/tickets" do
    # bd-1ozks5: `assignee` is still accepted for one release — the local
    # assignee field is gone, so it's ignored and reported back as a warning
    # rather than rejected outright.
    test "accepts and ignores a deprecated `assignee`, with a warning", %{conn: conn, gh: ws} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 501, "html_url" => "https://github.com/o/r/issues/501"})
      end)

      conn =
        post(conn, ~p"/api/workspaces/#{ws.id}/tracker/tickets", %{
          "title" => "unclaimed work",
          "assignee" => "alice"
        })

      body = json_response(conn, 201)
      assert body["ref"] == "501"
      assert [warning] = body["warnings"]
      assert warning =~ "assignee"
    end

    test "no warnings key when assignee isn't passed", %{conn: conn, gh: ws} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 502, "html_url" => "https://github.com/o/r/issues/502"})
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/tracker/tickets", %{"title" => "clean"})

      body = json_response(conn, 201)
      refute Map.has_key?(body, "warnings")
    end
  end
end
