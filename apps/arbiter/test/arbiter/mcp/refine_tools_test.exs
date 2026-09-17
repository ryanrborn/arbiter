defmodule Arbiter.MCP.RefineToolsTest do
  @moduledoc """
  Data-level authorization for the `:refine` tier (bd-3uy2hn, acceptance 3, 4, 6).

  The tool-level table (`Arbiter.MCP.RefinePolicy`) says *which* tools a refine
  session may call; this file covers the second gate — that every write it may
  call still has to land inside the bound issue's `parent_of` subtree.

  The graph under test:

      grandparent
        ├── root  ← the bound issue
        │     └── child
        │           └── grandchild
        └── sibling

      unrelated (no edges)
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "refine-tools-ws", prefix: "rft"})

    make = fn title ->
      {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ac"})
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

    refine = %Scope{
      tier: :refine,
      workspace_id: ws.id,
      issue_id: root.id,
      session_id: "sess-refine"
    }

    {:ok,
     ws: ws,
     refine: refine,
     grandparent: grandparent,
     root: root,
     child: child,
     grandchild: grandchild,
     sibling: sibling,
     unrelated: unrelated}
  end

  defp call(scope, tool, args), do: Catalog.call(scope, tool, args)

  defp reload!(%Issue{id: id}), do: Ash.get!(Issue, id)

  describe "reads are broad within the bound workspace" do
    test "task_show reads an issue outside the subtree", ctx do
      assert {:ok, %{id: id}} = call(ctx.refine, "task_show", %{"id" => ctx.unrelated.id})
      assert id == ctx.unrelated.id
    end

    test "task_show with no id defaults to the bound issue", ctx do
      assert {:ok, %{id: id}} = call(ctx.refine, "task_show", %{})
      assert id == ctx.root.id
    end

    test "task_list returns the workspace's issues", ctx do
      assert {:ok, %{tasks: tasks}} = call(ctx.refine, "task_list", %{})
      ids = Enum.map(tasks, & &1.id)

      assert ctx.root.id in ids
      assert ctx.unrelated.id in ids
    end

    test "a task in another workspace is not found", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "refine-other-ws", prefix: "rfo"})
      {:ok, stranger} = Ash.create(Issue, %{title: "stranger", workspace_id: other_ws.id})

      assert {:tool_error, message} = call(ctx.refine, "task_show", %{"id" => stranger.id})
      assert message =~ "not found"
    end
  end

  describe "task_update — subtree only" do
    test "succeeds on the bound issue", ctx do
      assert {:ok, _} =
               call(ctx.refine, "task_update", %{
                 "id" => ctx.root.id,
                 "description" => "sharpened"
               })

      assert reload!(ctx.root).description == "sharpened"
    end

    test "succeeds on a parent_of grandchild", ctx do
      assert {:ok, _} =
               call(ctx.refine, "task_update", %{
                 "id" => ctx.grandchild.id,
                 "title" => "renamed grandchild"
               })

      assert reload!(ctx.grandchild).title == "renamed grandchild"
    end

    test "is refused on the bound issue's parent, a sibling and an unrelated issue", ctx do
      for target <- [ctx.grandparent, ctx.sibling, ctx.unrelated] do
        assert {:rpc_error, -32_003, message} =
                 call(ctx.refine, "task_update", %{"id" => target.id, "title" => "nope"})

        assert message =~ "subtree"
        assert reload!(target).title != "nope"
      end
    end

    test "refuses to change status even inside the subtree", ctx do
      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "task_update", %{"id" => ctx.root.id, "status" => "closed"})

      assert message =~ "status"
      assert reload!(ctx.root).status == :open
    end

    test "refuses a field outside the refine write set", ctx do
      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "task_update", %{"id" => ctx.root.id, "assignee" => "someone"})

      assert message =~ "assignee"
    end

    test "accepts the documented refine field set", ctx do
      assert {:ok, _} =
               call(ctx.refine, "task_update", %{
                 "id" => ctx.root.id,
                 "title" => "t",
                 "description" => "d",
                 "acceptance" => "- a",
                 "notes" => "n",
                 "issue_type" => "feature",
                 "difficulty" => 3,
                 "priority" => 1,
                 "verify_after_deploy" => true
               })

      updated = reload!(ctx.root)
      assert updated.issue_type == :feature
      assert updated.difficulty == 3
      assert updated.priority == 1
      assert updated.verify_after_deploy
    end
  end

  describe "task_update_progress — subtree only" do
    test "records notes on a descendant", ctx do
      assert {:ok, _} =
               call(ctx.refine, "task_update_progress", %{
                 "id" => ctx.child.id,
                 "notes" => "refined during session"
               })

      assert reload!(ctx.child).notes == "refined during session"
    end

    test "is refused outside the subtree", ctx do
      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "task_update_progress", %{
                 "id" => ctx.sibling.id,
                 "notes" => "nope"
               })

      assert message =~ "subtree"
      assert reload!(ctx.sibling).notes == nil
    end
  end

  describe "edges — at least one endpoint in the subtree" do
    test "dep_add links a subtree task to one outside it", ctx do
      assert {:ok, _} =
               call(ctx.refine, "dep_add", %{
                 "from_issue_id" => ctx.child.id,
                 "to_issue_id" => ctx.unrelated.id,
                 "type" => "relates_to"
               })
    end

    test "dep_add works when only the *to* endpoint is in the subtree", ctx do
      assert {:ok, _} =
               call(ctx.refine, "dep_add", %{
                 "from_issue_id" => ctx.unrelated.id,
                 "to_issue_id" => ctx.grandchild.id,
                 "type" => "relates_to"
               })
    end

    test "dep_add is refused when neither endpoint is in the subtree", ctx do
      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "dep_add", %{
                 "from_issue_id" => ctx.sibling.id,
                 "to_issue_id" => ctx.unrelated.id,
                 "type" => "relates_to"
               })

      assert message =~ "subtree"
      assert Dependencies.for_issue(ctx.sibling.id).relates_to == []
    end

    test "dep_remove follows the same rule", ctx do
      {:ok, _} = Dependencies.add(ctx.sibling.id, ctx.unrelated.id, :relates_to)

      assert {:rpc_error, -32_003, _} =
               call(ctx.refine, "dep_remove", %{
                 "from_issue_id" => ctx.sibling.id,
                 "to_issue_id" => ctx.unrelated.id
               })

      assert {:ok, %{removed: 1}} =
               call(ctx.refine, "dep_remove", %{
                 "from_issue_id" => ctx.root.id,
                 "to_issue_id" => ctx.child.id,
                 "type" => "parent_of"
               })
    end
  end

  describe "task_create — always inside the subtree" do
    test "lands in Backlog as a parent_of child of the bound issue", ctx do
      assert {:ok, %{id: new_id}} = call(ctx.refine, "task_create", %{"title" => "a new child"})

      created = Ash.get!(Issue, new_id)
      refute created.refined
      assert created.workspace_id == ctx.ws.id

      children = Dependencies.for_issue(ctx.root.id).children
      assert new_id in Enum.map(children, & &1.issue_id)
    end

    test "attaches to a named descendant instead of the bound issue", ctx do
      assert {:ok, %{id: new_id}} =
               call(ctx.refine, "task_create", %{
                 "title" => "grandchild's child",
                 "parent_id" => ctx.grandchild.id
               })

      children = Dependencies.for_issue(ctx.grandchild.id).children
      assert new_id in Enum.map(children, & &1.issue_id)
    end

    test "the response reports the parent it attached to", ctx do
      assert {:ok, result} = call(ctx.refine, "task_create", %{"title" => "reported"})
      assert result.parent_id == ctx.root.id
    end

    test "refuses a parent outside the subtree, and creates nothing", ctx do
      before = Issue |> Ash.Query.filter(workspace_id == ^ctx.ws.id) |> Ash.read!() |> length()

      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "task_create", %{
                 "title" => "smuggled",
                 "parent_id" => ctx.sibling.id
               })

      assert message =~ "subtree"

      assert Issue |> Ash.Query.filter(workspace_id == ^ctx.ws.id) |> Ash.read!() |> length() ==
               before
    end

    test "cannot create into another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "refine-create-other", prefix: "rco"})

      assert {:rpc_error, -32_003, _} =
               call(ctx.refine, "task_create", %{
                 "title" => "elsewhere",
                 "workspace" => other_ws.id
               })
    end
  end

  describe "task_promote — subtree only, acceptance still required" do
    test "promotes the bound issue and a grandchild", ctx do
      assert {:ok, _} = call(ctx.refine, "task_promote", %{"id" => ctx.root.id})
      assert {:ok, _} = call(ctx.refine, "task_promote", %{"id" => ctx.grandchild.id})

      assert reload!(ctx.root).refined
      assert reload!(ctx.grandchild).refined
    end

    test "is refused outside the subtree", ctx do
      assert {:rpc_error, -32_003, message} =
               call(ctx.refine, "task_promote", %{"id" => ctx.sibling.id})

      assert message =~ "subtree"
      refute reload!(ctx.sibling).refined
    end

    test "still refuses a gated type with no acceptance (bd-7mbrlg)", ctx do
      assert {:ok, %{id: new_id}} =
               call(ctx.refine, "task_create", %{"title" => "no ACs", "issue_type" => "feature"})

      assert {:tool_error, message} = call(ctx.refine, "task_promote", %{"id" => new_id})
      assert message =~ "acceptance"
      refute Ash.get!(Issue, new_id).refined
    end

    test "the response spells out edges-before-promote", ctx do
      assert {:ok, result} = call(ctx.refine, "task_promote", %{"id" => ctx.root.id})

      assert is_binary(result.promotion_note)
      assert result.promotion_note =~ "edge"
    end

    test "the catalog description documents edges-before-promote" do
      %{description: description} = Enum.find(Catalog.all(), &(&1.name == "task_promote"))

      assert description =~ "edge"
    end
  end
end
