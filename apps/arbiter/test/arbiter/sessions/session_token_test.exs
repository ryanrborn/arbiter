defmodule Arbiter.Sessions.SessionTokenTest do
  @moduledoc """
  The per-session, revocable MCP scope token (bd-aprlbb, RFC §9.3 / §10.1).

  Acceptance criterion 3: minted at `--tier coordinator`, `can_dispatch`
  defaults **off**, the workspace binding is honoured, and ending or killing
  the session revokes it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    SessionEnv.sandbox("session-token")
    SessionRunnerStub.reset()
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.merge([runner: SessionRunnerStub], opts))
    session
  end

  describe "minting (§9.3)" do
    test "is a coordinator-tier token carrying the session id" do
      session = launch!()
      token = Sessions.mint_mcp_token(session)

      assert {:ok, scope} = Scope.from_token(token)
      assert scope.tier == :coordinator
      assert scope.session_id == session.id
    end

    test "can_dispatch defaults off (§10.1 recursion guardrail)" do
      session = launch!()

      assert {:ok, scope} = Scope.from_token(Sessions.mint_mcp_token(session))
      refute scope.can_dispatch
    end

    test "can_dispatch is honoured when the operator opts in" do
      session = launch!(can_dispatch: true)

      assert session.can_dispatch
      assert {:ok, scope} = Scope.from_token(Sessions.mint_mcp_token(session))
      assert scope.can_dispatch
    end

    test "cross-workspace by default, bound when the session is bound" do
      cross = launch!()
      assert {:ok, scope} = Scope.from_token(Sessions.mint_mcp_token(cross))
      assert scope.workspace_id == nil
      assert Scope.same_workspace?(scope, "any-workspace")

      bound = launch!(workspace_id: "ws-42")
      assert {:ok, bound_scope} = Scope.from_token(Sessions.mint_mcp_token(bound))
      assert bound_scope.workspace_id == "ws-42"
      assert Scope.same_workspace?(bound_scope, "ws-42")
      refute Scope.same_workspace?(bound_scope, "ws-other")
    end
  end

  describe "revocation — the session row is the handle (§9.3)" do
    test "a live session's token verifies" do
      session = launch!()
      assert {:ok, _} = Scope.from_token(Sessions.mint_mcp_token(session))
    end

    test "killing the session revokes its token" do
      session = launch!()
      token = Sessions.mint_mcp_token(session)
      assert {:ok, _} = Scope.from_token(token)

      {:ok, killed} = Sessions.kill(session.id, runner: SessionRunnerStub)

      assert killed.mcp_token_revoked_at
      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "ending the session for any other reason revokes it too" do
      session = launch!()
      token = Sessions.mint_mcp_token(session)

      {:ok, _} = Sessions.mark_ended(session, "scope vanished")

      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "revoke_mcp_token/1 revokes without ending the session" do
      session = launch!()
      token = Sessions.mint_mcp_token(session)

      {:ok, revoked} = Sessions.revoke_mcp_token(session)

      assert revoked.status == :running
      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "a token naming a session with no row is revoked, not accepted" do
      token = Scope.mint_session(Ash.UUID.generate())
      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "tokens with no session id are unaffected by the revocation check" do
      assert {:ok, scope} = Scope.from_token(Scope.mint_coordinator())
      assert scope.session_id == nil
    end
  end
end
