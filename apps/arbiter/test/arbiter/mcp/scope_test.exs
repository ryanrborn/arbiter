defmodule Arbiter.MCP.ScopeTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Scope

  describe "mint_polecat/3 + from_token/1" do
    test "round-trips the polecat claims, never carrying can_sling" do
      token = Scope.mint_polecat(%{id: "bd-1", workspace_id: "ws-1"}, "shipyard")

      assert {:ok, scope} = Scope.from_token(token)
      assert scope.tier == :polecat
      assert scope.workspace_id == "ws-1"
      assert scope.bead_id == "bd-1"
      assert scope.rig == "shipyard"
      refute scope.can_sling
      assert scope.depth == 0
    end

    test "rig is optional" do
      token = Scope.mint_polecat(%{id: "bd-1", workspace_id: "ws-1"})
      assert {:ok, %Scope{rig: nil}} = Scope.from_token(token)
    end
  end

  describe "mint_coordinator/2 + from_token/1" do
    test "round-trips coordinator claims with can_sling on by default" do
      token = Scope.mint_coordinator("ws-9")

      assert {:ok, scope} = Scope.from_token(token)
      assert scope.tier == :coordinator
      assert scope.workspace_id == "ws-9"
      assert scope.bead_id == nil
      assert scope.can_sling
    end

    test "can_sling can be disabled" do
      token = Scope.mint_coordinator("ws-9", can_sling: false)
      assert {:ok, %Scope{can_sling: false}} = Scope.from_token(token)
    end
  end

  describe "from_token/1 validation" do
    test "rejects a garbage token" do
      assert {:error, :invalid} = Scope.from_token("not-a-real-token")
    end

    test "rejects a non-binary" do
      assert {:error, :invalid} = Scope.from_token(nil)
    end

    test "rejects an expired token" do
      # Plug.Crypto.sign/4 takes :signed_at in seconds; backdate well past max_age.
      past = System.system_time(:second) - 100_000
      token = Scope.mint_polecat(%{id: "bd-1", workspace_id: "ws-1"}, "rig", signed_at: past)
      assert {:error, :expired} = Scope.from_token(token)
    end
  end

  describe "own_bead/2" do
    setup do
      %{
        polecat: %Scope{tier: :polecat, workspace_id: "w", bead_id: "bd-1"},
        coordinator: %Scope{tier: :coordinator, workspace_id: "w"}
      }
    end

    test "polecat defaults to its bound bead when the arg is nil", %{polecat: pc} do
      assert Scope.own_bead(pc, nil) == {:ok, "bd-1"}
    end

    test "polecat allows its own bead id explicitly", %{polecat: pc} do
      assert Scope.own_bead(pc, "bd-1") == {:ok, "bd-1"}
    end

    test "polecat rejects any other bead id", %{polecat: pc} do
      assert Scope.own_bead(pc, "bd-2") == {:error, :unauthorized}
    end

    test "coordinator requires an explicit id", %{coordinator: co} do
      assert Scope.own_bead(co, nil) == {:error, :missing}
      assert Scope.own_bead(co, "") == {:error, :missing}
      assert Scope.own_bead(co, "bd-2") == {:ok, "bd-2"}
    end
  end

  describe "same_workspace?/2" do
    test "matches only the bound workspace" do
      scope = %Scope{tier: :coordinator, workspace_id: "w"}
      assert Scope.same_workspace?(scope, "w")
      refute Scope.same_workspace?(scope, "other")
      refute Scope.same_workspace?(scope, nil)
    end
  end
end
