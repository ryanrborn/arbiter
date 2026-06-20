defmodule Arbiter.Tasks.IssueProgressTest do
  @moduledoc """
  Unit coverage for the unified parent-with-progress concept: a task's
  `:child_total` / `:child_closed` rollup over its `:parent_of` children, and the
  `auto_close` flag that closes a parent once all its children are done. This is
  the surface that replaced the removed `Convoy` / `ConvoyMembership` resources.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "progress-ws", prefix: "pg"})
    {:ok, ws: ws}
  end

  defp child_of(parent, child) do
    {:ok, _} =
      Ash.create(Dependency, %{
        from_issue_id: parent.id,
        to_issue_id: child.id,
        type: :parent_of
      })
  end

  describe "child-progress calculations" do
    test "count children and closed children over :parent_of edges", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})
      {:ok, c3} = Ash.create(Issue, %{title: "c3", workspace_id: ws.id})

      Enum.each([c1, c2, c3], &child_of(parent, &1))
      {:ok, _} = Ash.update(c1, %{}, action: :close)

      parent = Ash.load!(parent, [:child_total, :child_closed])
      assert parent.child_total == 3
      assert parent.child_closed == 1
    end

    test "a leaf task has zero children", %{ws: ws} do
      {:ok, leaf} = Ash.create(Issue, %{title: "leaf", workspace_id: ws.id})
      leaf = Ash.load!(leaf, [:child_total, :child_closed])
      assert leaf.child_total == 0
      assert leaf.child_closed == 0
    end

    test "only :parent_of edges count — other dep types are ignored", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, related} = Ash.create(Issue, %{title: "related", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: related.id,
          type: :relates_to
        })

      parent = Ash.load!(parent, [:child_total, :child_closed])
      assert parent.child_total == 0
    end
  end

  describe "auto_close" do
    test "an auto_close parent closes when the last child closes", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})

      Enum.each([c1, c2], &child_of(parent, &1))

      {:ok, _} = Ash.update(c1, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).status == :open

      {:ok, _} = Ash.update(c2, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).status == :closed
    end

    test "a parent without auto_close stays open even when all children close", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "owned epic", workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      child_of(parent, c1)

      {:ok, _} = Ash.update(c1, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).status == :open
    end

    test "auto_close with no children never closes the parent", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "childless", auto_close: true, workspace_id: ws.id})

      assert Issue.maybe_auto_close(parent).status == :open
    end

    test "closing a child cascades up a chain of auto_close ancestors", %{ws: ws} do
      {:ok, grandparent} =
        Ash.create(Issue, %{title: "grandparent", auto_close: true, workspace_id: ws.id})

      {:ok, parent} = Ash.create(Issue, %{title: "parent", auto_close: true, workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})

      child_of(grandparent, parent)
      child_of(parent, child)

      {:ok, _} = Ash.update(child, %{}, action: :close)

      assert Ash.get!(Issue, parent.id).status == :closed
      assert Ash.get!(Issue, grandparent.id).status == :closed
    end

    test "a child with two parents rolls up into each", %{ws: ws} do
      {:ok, p1} = Ash.create(Issue, %{title: "p1", auto_close: true, workspace_id: ws.id})
      {:ok, p2} = Ash.create(Issue, %{title: "p2", workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "shared child", workspace_id: ws.id})

      child_of(p1, child)
      child_of(p2, child)

      {:ok, _} = Ash.update(child, %{}, action: :close)

      # p1 auto-closes; p2 (no auto_close) stays open but still counts the child.
      assert Ash.get!(Issue, p1.id).status == :closed
      p2 = Ash.load!(Ash.get!(Issue, p2.id), [:child_total, :child_closed])
      assert p2.status == :open
      assert p2.child_total == 1
      assert p2.child_closed == 1
    end
  end
end
