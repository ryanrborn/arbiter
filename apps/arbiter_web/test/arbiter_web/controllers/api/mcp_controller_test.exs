defmodule ArbiterWeb.Api.McpControllerTest do
  @moduledoc """
  `POST /api/mcp/tokens` — bd-5b5hq7's caller-inheritance guardrail.

  A minted token must never exceed the caller that minted it: same
  `session_id` (so it's revoked when the session ends), same-or-narrower
  workspace binding, `can_dispatch` no greater than the caller's. Anonymous
  loopback callers (no bearer token — the zero-setup `arb` / `arb init` path)
  keep minting full-power coordinator tokens, unchanged.
  """
  use ArbiterWeb.ConnCase, async: true

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions.Session

  defp session_fixture(attrs \\ %{}) do
    Ash.create!(Session, Map.merge(%{cwd: "/tmp/mcp-controller-test-cwd"}, Map.new(attrs)))
  end

  describe "anonymous loopback (no caller token)" do
    test "mints a full-power, workspace-agnostic coordinator token", %{conn: conn} do
      resp = conn |> post("/api/mcp/tokens", %{}) |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.tier == :coordinator
      assert scope.workspace_id == nil
      assert scope.session_id == nil
      assert scope.can_dispatch == true
    end

    test "may still narrow itself via workspace_id / can_dispatch params", %{conn: conn} do
      resp =
        conn
        |> post("/api/mcp/tokens", %{"workspace_id" => "ws-1", "can_dispatch" => false})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.workspace_id == "ws-1"
      assert scope.can_dispatch == false
    end

    test "a form-encoded can_dispatch=\"false\" string narrows, not upgrades", %{conn: conn} do
      resp =
        conn
        |> post("/api/mcp/tokens", %{"can_dispatch" => "false"})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.can_dispatch == false
    end
  end

  describe "session-token caller" do
    setup do
      {:ok, session_id: session_fixture().id}
    end

    test "minted token inherits the caller's session_id (revocable)", %{
      conn: conn,
      session_id: session_id
    } do
      caller_token = Scope.mint_session(session_id)

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.session_id == session_id
    end

    test "minted token cannot exceed the caller's can_dispatch: false", %{
      conn: conn,
      session_id: session_id
    } do
      caller_token = Scope.mint_session(session_id, can_dispatch: false)

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{"can_dispatch" => true})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.can_dispatch == false
    end

    test "minted token stays workspace-bound when the caller is bound", %{
      conn: conn,
      session_id: session_id
    } do
      caller_token = Scope.mint_session(session_id, workspace_id: "ws-1")

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{"workspace_id" => "ws-2"})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.workspace_id == "ws-1"
    end

    test "an ended session's token can no longer mint (revoked upstream by ApiAuth)", %{
      conn: conn,
      session_id: session_id
    } do
      caller_token = Scope.mint_session(session_id)

      session = Ash.get!(Session, session_id)
      {:ok, _} = Arbiter.Sessions.revoke_mcp_token(session)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{})

      assert conn.status == 401
    end
  end

  describe "worker-tier caller" do
    test "is refused — workers cannot mint new tokens", %{conn: conn} do
      caller_token = Scope.mint_worker(%{id: "task-1", workspace_id: "ws-1"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{})

      resp = json_response(conn, 403)
      assert is_binary(resp["error"]["message"])
    end
  end

  describe "plain coordinator-token caller (no session_id)" do
    test "minted token cannot exceed the caller's workspace binding", %{conn: conn} do
      caller_token = Scope.mint_coordinator("ws-1")

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{"workspace_id" => "ws-2"})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.workspace_id == "ws-1"
      assert scope.session_id == nil
    end

    test "an unbound caller may mint a narrower, workspace-bound token", %{conn: conn} do
      caller_token = Scope.mint_coordinator(nil)

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{caller_token}")
        |> post("/api/mcp/tokens", %{"workspace_id" => "ws-2"})
        |> json_response(200)

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.workspace_id == "ws-2"
    end
  end
end
