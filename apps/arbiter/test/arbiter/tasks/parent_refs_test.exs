defmodule Arbiter.Tasks.ParentRefsTest do
  @moduledoc """
  bd-38of5i / design bd-2s901b §7: what a child's detail page needs to say
  "↳ Part of bd-epic — … • 9/14 closed", including the four edge cases and the
  sibling position that is only shown when it is a fact.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.ParentRefs
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "parent-refs-#{System.unique_integer([:positive])}",
        prefix: "prf#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp issue(ws, title, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: title, workspace_id: ws.id}, attrs))

    issue
  end

  defp close(issue) do
    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  describe "for_issue/1" do
    test "an issue with no parent has no refs", %{ws: ws} do
      assert ParentRefs.for_issue(issue(ws, "lonely")) == []
    end

    test "an epic parent carries its title, type, status and child progress", %{ws: ws} do
      epic = issue(ws, "Browser coordinator sessions", %{issue_type: :epic})
      child = issue(ws, "the terminal channel")
      sibling = issue(ws, "the transport")

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(epic.id, sibling.id, :parent_of)
      close(sibling)

      assert [ref] = ParentRefs.for_issue(child)

      assert ref.id == epic.id
      assert ref.title == "Browser coordinator sessions"
      assert ref.issue_type == :epic
      assert ref.status == :open
      assert ref.child_total == 2
      assert ref.child_closed == 1
      assert ref.workspace_name == nil
    end

    # Edge case: >1 `parent_of` edge. Stacked, most recently updated first,
    # rather than picking one arbitrarily.
    test "multiple parents come back most-recently-updated first", %{ws: ws} do
      older = issue(ws, "Older epic", %{issue_type: :epic})
      newer = issue(ws, "Newer epic", %{issue_type: :epic})
      child = issue(ws, "a child of two")

      {:ok, _} = Dependencies.add(older.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(newer.id, child.id, :parent_of)

      # Touch the older one last, so recency and creation order disagree.
      {:ok, older} = Ash.update(older, %{title: "Older epic, renamed"})

      assert [first, second] = ParentRefs.for_issue(child)
      assert first.id == older.id
      assert second.id == newer.id
    end

    # Edge case: a plain task with subtasks. Same edge, none of the epic
    # chrome — the component reads `issue_type` to decide.
    test "a non-epic parent comes back with its own type", %{ws: ws} do
      parent = issue(ws, "Split the importer", %{issue_type: :task})
      child = issue(ws, "step one")

      {:ok, _} = Dependencies.add(parent.id, child.id, :parent_of)

      assert [%{issue_type: :task, id: id}] = ParentRefs.for_issue(child)
      assert id == parent.id
    end

    # Edge case: the epic is done. Still true, so it still renders.
    test "a closed epic reports its closed status and a full count", %{ws: ws} do
      epic = issue(ws, "Wave one", %{issue_type: :epic})
      child = issue(ws, "the only child")

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      close(child)
      close(epic)

      assert [ref] = ParentRefs.for_issue(Ash.get!(Issue, child.id))
      assert ref.status == :closed
      assert ref.child_total == 1
      assert ref.child_closed == 1
    end

    # Edge case: the parent lives elsewhere. `Dependencies.add/4` refuses to
    # create one of these, but pre-facade rows exist, so the banner has to
    # render them — tagged with the other workspace's name.
    test "a cross-workspace parent carries the other workspace's name", %{ws: ws} do
      {:ok, other} =
        Ash.create(Workspace, %{
          name: "vstim-#{System.unique_integer([:positive])}",
          prefix: "vst#{System.unique_integer([:positive])}"
        })

      epic = issue(other, "Candle store", %{issue_type: :epic})
      child = issue(ws, "a child across the line")

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: epic.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      assert [ref] = ParentRefs.for_issue(child)
      assert ref.workspace_name == other.name
    end

    test "the sibling position is filled in when the children form one depends_on chain", %{
      ws: ws
    } do
      epic = issue(ws, "Three in a row", %{issue_type: :epic})
      [a, b, c] = for t <- ~w(first second third), do: issue(ws, t)

      for child <- [a, b, c], do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

      {:ok, _} = Dependencies.add(b.id, a.id, :depends_on)
      {:ok, _} = Dependencies.add(c.id, b.id, :depends_on)

      assert [%{position: {2, 3}}] = ParentRefs.for_issue(b)
      assert [%{position: {1, 3}}] = ParentRefs.for_issue(a)
      assert [%{position: {3, 3}}] = ParentRefs.for_issue(c)
    end

    test "the sibling position is omitted when the order is ambiguous", %{ws: ws} do
      epic = issue(ws, "Unordered", %{issue_type: :epic})
      [a, b, c] = for t <- ~w(first second third), do: issue(ws, t)

      for child <- [a, b, c], do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

      # Only one of the three edges a full chain would need.
      {:ok, _} = Dependencies.add(b.id, a.id, :depends_on)

      assert [%{position: nil}] = ParentRefs.for_issue(b)
    end
  end

  describe "chain_position/3" do
    test "an unbroken chain gives every sibling a position" do
      sibs = ~w(a b c d)
      pairs = [{"b", "a"}, {"c", "b"}, {"d", "c"}]

      assert ParentRefs.chain_position("a", sibs, pairs) == {1, 4}
      assert ParentRefs.chain_position("c", sibs, pairs) == {3, 4}
      assert ParentRefs.chain_position("d", sibs, pairs) == {4, 4}
    end

    test "no edges at all is ambiguous, not position 1" do
      assert ParentRefs.chain_position("a", ~w(a b c), []) == nil
    end

    test "a partial chain is ambiguous" do
      assert ParentRefs.chain_position("a", ~w(a b c), [{"b", "a"}]) == nil
    end

    test "two siblings blocked on the same one is a fork, not a chain" do
      pairs = [{"b", "a"}, {"c", "a"}]
      assert ParentRefs.chain_position("a", ~w(a b c), pairs) == nil
    end

    test "one sibling blocked on two is a join, not a chain" do
      pairs = [{"c", "a"}, {"c", "b"}]
      assert ParentRefs.chain_position("a", ~w(a b c), pairs) == nil
    end

    test "a cycle never resolves to a position" do
      pairs = [{"a", "b"}, {"b", "c"}, {"c", "a"}]
      assert ParentRefs.chain_position("a", ~w(a b c), pairs) == nil
    end

    test "edges to non-siblings are ignored rather than counted" do
      pairs = [{"b", "a"}, {"c", "b"}, {"a", "zz-outside"}]
      assert ParentRefs.chain_position("b", ~w(a b c), pairs) == {2, 3}
    end

    test "an only child has no position to show" do
      assert ParentRefs.chain_position("a", ~w(a), []) == nil
    end

    test "a child that is not among the siblings has no position" do
      assert ParentRefs.chain_position("zz", ~w(a b), [{"b", "a"}]) == nil
    end
  end
end
