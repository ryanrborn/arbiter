defmodule Arbiter.MCP.RefineScopeTest do
  @moduledoc """
  The `:refine` tier of `Arbiter.MCP.Scope` (bd-3uy2hn): a token bound to one
  issue, with authority over that issue's `parent_of` subtree only.

  Acceptance criterion 1 — mint/verify round-trip, `can_dispatch` always false,
  and revocation when the bound session ends — plus the subtree predicate
  criterion 3 leans on.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  describe "tiers/0" do
    test "names the refine tier alongside worker and coordinator" do
      assert :refine in Scope.tiers()
      assert :worker in Scope.tiers()
      assert :coordinator in Scope.tiers()
    end
  end

  describe "mint_refine/4 + from_token/1" do
    setup do
      SessionEnv.sandbox("refine-scope")
      SessionRunnerStub.reset()
      {:ok, session} = Sessions.launch(runner: SessionRunnerStub)
      {:ok, session: session}
    end

    test "round-trips the workspace, issue and session claims", %{session: session} do
      token = Scope.mint_refine(session.id, "ws-1", "bd-root")

      assert {:ok, scope} = Scope.from_token(token)
      assert scope.tier == :refine
      assert scope.workspace_id == "ws-1"
      assert scope.issue_id == "bd-root"
      assert scope.session_id == session.id
      assert scope.task_id == nil
    end

    test "can_dispatch is always false, even when the caller asks for it", %{session: session} do
      token = Scope.mint_refine(session.id, "ws-1", "bd-root", can_dispatch: true)

      assert {:ok, %Scope{can_dispatch: false}} = Scope.from_token(token)
    end

    test "a claim blob asserting can_dispatch still decodes as false" do
      # Defence in depth: the tier, not the claim, decides. A forged-shape claim
      # (or a future mint bug) cannot hand a refine token dispatch.
      token =
        Arbiter.MCP.mint(%{
          tier: :refine,
          workspace_id: "ws-1",
          issue_id: "bd-root",
          session_id: nil,
          can_dispatch: true,
          can_sling: true,
          depth: 0
        })

      assert {:ok, %Scope{tier: :refine, can_dispatch: false}} = Scope.from_token(token)
    end

    test "a refine claim without a workspace or issue is invalid" do
      no_issue =
        Arbiter.MCP.mint(%{tier: :refine, workspace_id: "ws-1", session_id: "s", depth: 0})

      no_ws =
        Arbiter.MCP.mint(%{tier: :refine, issue_id: "bd-root", session_id: "s", depth: 0})

      assert {:error, :invalid} = Scope.from_token(no_issue)
      assert {:error, :invalid} = Scope.from_token(no_ws)
    end

    test "expires like every other scope token", %{session: session} do
      past = System.system_time(:second) - 100_000
      token = Scope.mint_refine(session.id, "ws-1", "bd-root", signed_at: past)

      assert {:error, :expired} = Scope.from_token(token)
    end
  end

  describe "revocation — the session row is the handle" do
    setup do
      SessionEnv.sandbox("refine-scope-revoke")
      SessionRunnerStub.reset()
      :ok
    end

    test "ending the session stops the refine token verifying" do
      {:ok, session} = Sessions.launch(runner: SessionRunnerStub)
      token = Scope.mint_refine(session.id, "ws-1", "bd-root")
      assert {:ok, %Scope{tier: :refine}} = Scope.from_token(token)

      {:ok, killed} = Sessions.kill(session.id, runner: SessionRunnerStub)
      assert killed.mcp_token_revoked_at

      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "a refine token naming a session with no row at all is revoked" do
      token = Scope.mint_refine(Ecto.UUID.generate(), "ws-1", "bd-root")

      assert {:error, :revoked} = Scope.from_token(token)
    end
  end

  describe "own_task/2" do
    test "defaults to the bound issue and accepts any explicit id (reads are broad)" do
      scope = %Scope{tier: :refine, workspace_id: "w", issue_id: "bd-root"}

      assert Scope.own_task(scope, nil) == {:ok, "bd-root"}
      assert Scope.own_task(scope, "bd-root") == {:ok, "bd-root"}
      # Reading a related issue is deliberately permitted; the *write* gate is
      # the subtree check, not own_task.
      assert Scope.own_task(scope, "bd-elsewhere") == {:ok, "bd-elsewhere"}
    end
  end

  describe "same_workspace?/2" do
    test "a refine scope is bound to exactly one workspace" do
      scope = %Scope{tier: :refine, workspace_id: "w", issue_id: "bd-root"}

      assert Scope.same_workspace?(scope, "w")
      refute Scope.same_workspace?(scope, "other")
      refute Scope.same_workspace?(scope, nil)
    end
  end

  describe "subtree_member?/2" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "refine-subtree-ws", prefix: "rst"})

      make = fn title ->
        {:ok, issue} =
          Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ac"})

        issue
      end

      grandparent = make.("grandparent")
      root = make.("the bound issue")
      child = make.("child")
      grandchild = make.("grandchild")
      sibling = make.("sibling")
      unrelated = make.("unrelated")

      {:ok, _} = Dependencies.add(grandparent.id, root.id, :parent_of)
      {:ok, _} = Dependencies.add(grandparent.id, sibling.id, :parent_of)
      {:ok, _} = Dependencies.add(root.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(child.id, grandchild.id, :parent_of)

      scope = %Scope{tier: :refine, workspace_id: ws.id, issue_id: root.id}

      {:ok,
       scope: scope,
       root: root,
       child: child,
       grandchild: grandchild,
       sibling: sibling,
       grandparent: grandparent,
       unrelated: unrelated}
    end

    test "the bound issue itself is in the subtree", ctx do
      assert Scope.subtree_member?(ctx.scope, ctx.root.id)
    end

    test "a child and a grandchild are in the subtree", ctx do
      assert Scope.subtree_member?(ctx.scope, ctx.child.id)
      assert Scope.subtree_member?(ctx.scope, ctx.grandchild.id)
    end

    test "the parent, a sibling and an unrelated issue are not", ctx do
      refute Scope.subtree_member?(ctx.scope, ctx.grandparent.id)
      refute Scope.subtree_member?(ctx.scope, ctx.sibling.id)
      refute Scope.subtree_member?(ctx.scope, ctx.unrelated.id)
    end

    test "a non-parent_of edge does not extend the subtree", ctx do
      {:ok, _} = Dependencies.add(ctx.root.id, ctx.unrelated.id, :relates_to)

      refute Scope.subtree_member?(ctx.scope, ctx.unrelated.id)
    end

    test "worker and coordinator scopes have no subtree concept", ctx do
      worker = %Scope{tier: :worker, workspace_id: ctx.scope.workspace_id, task_id: ctx.root.id}
      coordinator = %Scope{tier: :coordinator}

      refute Scope.subtree_member?(worker, ctx.root.id)
      refute Scope.subtree_member?(coordinator, ctx.root.id)
    end
  end
end
