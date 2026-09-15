defmodule Arbiter.Tasks.DependenciesTest do
  @moduledoc """
  bd-apj0gq — the `Arbiter.Tasks.Dependencies` facade: the single entry point
  for dependency-edge writes (cycle check, cross-workspace rejection, auto_close
  re-evaluation, paper trail, broadcast).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "deps-ws-#{System.unique_integer([:positive])}",
        prefix: "dps#{System.unique_integer([:positive])}"
      })

    {:ok, a} = Ash.create(Issue, %{title: "issue A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "issue B", workspace_id: ws.id})
    {:ok, c} = Ash.create(Issue, %{title: "issue C", workspace_id: ws.id})

    {:ok, ws: ws, a: a, b: b, c: c}
  end

  defp lifecycle_ids(count) do
    for _ <- 1..count do
      assert_receive {:task_lifecycle, :updated, issue}, 500
      issue.id
    end
  end

  defp edge(from, to, type) do
    {:ok, dep} =
      Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: type})

    dep
  end

  # ---- add/4 --------------------------------------------------------------

  describe "add/4" do
    test "creates the edge and returns it", %{a: a, b: b} do
      assert {:ok, dep} = Dependencies.add(a.id, b.id, :depends_on)
      assert dep.from_issue_id == a.id
      assert dep.to_issue_id == b.id
      assert dep.type == :depends_on
    end

    test "accepts a string type", %{a: a, b: b} do
      assert {:ok, dep} = Dependencies.add(a.id, b.id, "blocks")
      assert dep.type == :blocks
    end

    test "rejects an unknown type without touching the DB", %{a: a, b: b} do
      assert {:error, {:invalid_type, msg}} = Dependencies.add(a.id, b.id, "nonsense")
      assert msg =~ "nonsense"
      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "stamps notes and created_by from opts", %{a: a, b: b} do
      assert {:ok, dep} =
               Dependencies.add(a.id, b.id, :relates_to,
                 notes: "because",
                 created_by: "dashboard"
               )

      assert dep.notes == "because"
      assert dep.created_by == "dashboard"
    end

    test "reports an unknown endpoint as not_found", %{a: a} do
      assert {:error, {:not_found, msg}} = Dependencies.add(a.id, "bd-nope", :blocks)
      assert msg =~ "bd-nope"

      assert {:error, {:not_found, msg}} = Dependencies.add("bd-nope", a.id, :blocks)
      assert msg =~ "bd-nope"
    end

    test "self-reference still fails via the resource", %{a: a} do
      assert {:error, %Ash.Error.Invalid{}} = Dependencies.add(a.id, a.id, :blocks)
    end

    test "a duplicate edge still fails via the unique identity", %{a: a, b: b} do
      assert {:ok, _} = Dependencies.add(a.id, b.id, :blocks)
      assert {:error, %Ash.Error.Invalid{}} = Dependencies.add(a.id, b.id, :blocks)
    end
  end

  # ---- cross-workspace ----------------------------------------------------

  describe "add/4 cross-workspace rejection" do
    setup %{} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "deps-other-#{System.unique_integer([:positive])}",
          prefix: "dpo#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})
      {:ok, other_ws: other_ws, foreign: foreign}
    end

    test "rejects an edge whose endpoints live in different workspaces", ctx do
      assert {:error, {:cross_workspace, msg}} =
               Dependencies.add(ctx.a.id, ctx.foreign.id, :blocks)

      assert msg =~ ctx.ws.name
      assert msg =~ ctx.other_ws.name
      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "remove/3 still clears a pre-existing cross-workspace edge", ctx do
      # Written before the guard existed (REST used to allow it). It must stay
      # removable or it becomes an unremovable blocker.
      _ = edge(ctx.a, ctx.foreign, :depends_on)

      assert {:ok, 1} = Dependencies.remove(ctx.a.id, ctx.foreign.id)
    end
  end

  # ---- cycles -------------------------------------------------------------

  describe "add/4 cycle rejection" do
    test "rejects a 2-hop depends_on cycle and names it", %{a: a, b: b} do
      _ = edge(b, a, :depends_on)

      assert {:error, {:cyclic, msg}} = Dependencies.add(a.id, b.id, :depends_on)
      assert msg =~ a.id
      assert msg =~ b.id
      assert msg =~ "→"

      # Nothing persisted beyond the pre-existing edge.
      assert [%{from_issue_id: from}] = Ash.read!(Dependency)
      assert from == b.id
    end

    test "rejects the blocks inverse of the same cycle", %{a: a, b: b} do
      # a depends_on b ⇒ a waits for b. `b blocks a` also means a waits for b —
      # adding `a blocks b` closes the loop.
      _ = edge(a, b, :depends_on)

      assert {:error, {:cyclic, msg}} = Dependencies.add(a.id, b.id, :blocks)
      assert msg =~ a.id
      assert msg =~ b.id
    end

    test "rejects a 3-hop cycle", %{a: a, b: b, c: c} do
      _ = edge(a, b, :depends_on)
      _ = edge(b, c, :depends_on)

      assert {:error, {:cyclic, msg}} = Dependencies.add(c.id, a.id, :depends_on)
      assert msg =~ a.id
      assert msg =~ b.id
      assert msg =~ c.id
    end

    test "allows a DAG", %{a: a, b: b, c: c} do
      assert {:ok, _} = Dependencies.add(a.id, b.id, :depends_on)
      assert {:ok, _} = Dependencies.add(b.id, c.id, :depends_on)
      assert {:ok, _} = Dependencies.add(a.id, c.id, :depends_on)
    end

    test "never cycle-checks non-gating types", %{a: a, b: b} do
      _ = edge(a, b, :parent_of)
      assert {:ok, _} = Dependencies.add(b.id, a.id, :parent_of)

      _ = edge(a, b, :relates_to)
      assert {:ok, _} = Dependencies.add(b.id, a.id, :relates_to)

      _ = edge(a, b, :discovered_from)
      assert {:ok, _} = Dependencies.add(b.id, a.id, :discovered_from)

      _ = edge(a, b, :conflicts_with)
      assert {:ok, _} = Dependencies.add(b.id, a.id, :conflicts_with)
    end

    test "an unrelated pre-existing cycle does not block a new edge", %{ws: ws, a: a, b: b} do
      # A legacy cyclic pair, writable before this facade existed (the REST path
      # had no validation) and still reachable from seeds. It must not veto an
      # edge that touches neither of its endpoints, nor be named in any error.
      _ = edge(a, b, :depends_on)
      _ = edge(b, a, :depends_on)

      {:ok, p} = Ash.create(Issue, %{title: "issue P", workspace_id: ws.id})
      {:ok, q} = Ash.create(Issue, %{title: "issue Q", workspace_id: ws.id})

      assert {:ok, dep} = Dependencies.add(p.id, q.id, :depends_on)
      assert dep.from_issue_id == p.id
      refute Dependencies.would_cycle?(p.id, q.id, :depends_on)
    end

    test "names only the candidate's own cycle when another exists", ctx do
      %{ws: ws, a: a, b: b, c: c} = ctx
      _ = edge(a, b, :depends_on)
      _ = edge(b, a, :depends_on)

      {:ok, p} = Ash.create(Issue, %{title: "issue P", workspace_id: ws.id})
      _ = edge(c, p, :depends_on)

      assert {:error, {:cyclic, msg}} = Dependencies.add(p.id, c.id, :depends_on)
      assert msg =~ "#{p.id} → #{c.id} → #{p.id}"
      refute msg =~ a.id
      refute msg =~ b.id
    end

    test "the check is global — it sees edges outside any graph", %{a: a, b: b, c: c} do
      _ = edge(a, b, :depends_on)
      _ = edge(b, c, :depends_on)

      assert Dependencies.would_cycle?(c.id, a.id, :depends_on)
      refute Dependencies.would_cycle?(a.id, c.id, :depends_on)
      refute Dependencies.would_cycle?(c.id, a.id, :relates_to)
    end
  end

  # ---- auto_close ---------------------------------------------------------

  describe "parent_of auto_close re-evaluation" do
    test "adding an already-closed child closes the auto_close parent", ctx do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", workspace_id: ctx.ws.id, auto_close: true})

      {:ok, child} = Ash.update(ctx.a, %{}, action: :close)
      assert child.status == :closed

      assert {:ok, _dep} = Dependencies.add(parent.id, child.id, :parent_of)

      assert Ash.get!(Issue, parent.id).status == :closed
    end

    test "removing the last open child closes the auto_close parent", ctx do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", workspace_id: ctx.ws.id, auto_close: true})

      # b is done, a is not. The parent stays open while a is attached.
      {:ok, _} = Dependencies.add(parent.id, ctx.a.id, :parent_of)
      {:ok, _} = Dependencies.add(parent.id, ctx.b.id, :parent_of)
      {:ok, _} = Ash.update(ctx.b, %{}, action: :close)

      assert Ash.get!(Issue, parent.id).status == :open

      assert {:ok, 1} = Dependencies.remove(parent.id, ctx.a.id, :parent_of)
      assert Ash.get!(Issue, parent.id).status == :closed
    end

    test "does not close a parent that still has open children", ctx do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", workspace_id: ctx.ws.id, auto_close: true})

      {:ok, _} = Dependencies.add(parent.id, ctx.a.id, :parent_of)
      {:ok, _} = Dependencies.add(parent.id, ctx.b.id, :parent_of)
      {:ok, _} = Ash.update(ctx.b, %{}, action: :close)

      assert {:ok, 1} = Dependencies.remove(parent.id, ctx.b.id, :parent_of)
      assert Ash.get!(Issue, parent.id).status == :open
    end

    test "does not close a parent without auto_close", ctx do
      {:ok, parent} = Ash.create(Issue, %{title: "epic", workspace_id: ctx.ws.id})
      {:ok, child} = Ash.update(ctx.a, %{}, action: :close)

      assert {:ok, _} = Dependencies.add(parent.id, child.id, :parent_of)
      assert Ash.get!(Issue, parent.id).status == :open
    end
  end

  # ---- remove/3 -----------------------------------------------------------

  describe "remove/3" do
    test "removes every edge between the pair when no type is given", %{a: a, b: b} do
      _ = edge(a, b, :blocks)
      _ = edge(a, b, :relates_to)

      assert {:ok, 2} = Dependencies.remove(a.id, b.id)
      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "removes only the named type", %{a: a, b: b} do
      _ = edge(a, b, :blocks)
      kept = edge(a, b, :relates_to)

      assert {:ok, 1} = Dependencies.remove(a.id, b.id, :blocks)
      assert [%{id: id}] = Ash.read!(Dependency)
      assert id == kept.id
    end

    test "normalises a no-op removal to {:ok, 0}", %{a: a, b: b} do
      assert {:ok, 0} = Dependencies.remove(a.id, b.id)
      assert {:ok, 0} = Dependencies.remove(a.id, b.id, :blocks)
    end

    test "rejects an unknown type", %{a: a, b: b} do
      assert {:error, {:invalid_type, _}} = Dependencies.remove(a.id, b.id, "nonsense")
    end
  end

  # ---- for_issue/1 --------------------------------------------------------

  describe "for_issue/1" do
    test "groups edges by role rather than by raw direction", ctx do
      %{a: a, b: b, c: c} = ctx

      _ = edge(a, b, :depends_on)
      _ = edge(c, a, :depends_on)
      _ = edge(c, a, :parent_of)
      _ = edge(a, b, :parent_of)
      _ = edge(a, c, :relates_to)
      _ = edge(a, b, :conflicts_with)

      groups = Dependencies.for_issue(a.id)

      assert [%{issue_id: blocked_by}] = groups.blocked_by
      assert blocked_by == b.id

      assert [%{issue_id: blocking}] = groups.blocks
      assert blocking == c.id

      assert [%{issue_id: parent}] = groups.parents
      assert parent == c.id

      assert [%{issue_id: child}] = groups.children
      assert child == b.id

      assert [%{issue_id: related}] = groups.relates_to
      assert related == c.id

      assert [%{issue_id: conflict}] = groups.conflicts_with
      assert conflict == b.id
    end

    test "normalises a `blocks` edge into the gating buckets", %{a: a, b: b} do
      # b blocks a ⇒ a is blocked by b.
      _ = edge(b, a, :blocks)

      groups = Dependencies.for_issue(a.id)
      assert [%{issue_id: id}] = groups.blocked_by
      assert id == b.id
      assert groups.blocks == []
    end

    test "decorates each entry with the other endpoint's issue", %{a: a, b: b} do
      _ = edge(a, b, :depends_on)

      assert [%{issue: %Issue{} = other, edge: %Dependency{}}] =
               Dependencies.for_issue(a.id).blocked_by

      assert other.id == b.id
      assert other.title == "issue B"
    end

    test "is empty for an issue with no edges", %{a: a} do
      groups = Dependencies.for_issue(a.id)
      assert Enum.all?(Map.values(groups), &(&1 == []))
    end
  end

  # ---- audit + broadcast --------------------------------------------------

  describe "paper trail" do
    test "add and remove each write a version row", %{a: a, b: b} do
      assert {:ok, dep} = Dependencies.add(a.id, b.id, :blocks, created_by: "dashboard")

      versions = Ash.read!(Dependency.Version)
      assert [create_version] = versions
      assert create_version.version_source_id == dep.id
      assert create_version.version_action_type == :create

      assert {:ok, 1} = Dependencies.remove(a.id, b.id, :blocks)

      actions =
        Dependency.Version
        |> Ash.read!()
        |> Enum.map(& &1.version_action_type)

      assert :create in actions
      assert :destroy in actions
    end
  end

  describe "broadcast" do
    setup do
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "tasks")
      :ok
    end

    test "add broadcasts on \"tasks\" for both endpoints", %{a: a, b: b} do
      assert {:ok, _} = Dependencies.add(a.id, b.id, :relates_to)

      ids = lifecycle_ids(2)
      assert a.id in ids
      assert b.id in ids
    end

    test "remove broadcasts on \"tasks\" for both endpoints", %{a: a, b: b} do
      _ = edge(a, b, :relates_to)

      assert {:ok, 1} = Dependencies.remove(a.id, b.id)

      ids = lifecycle_ids(2)
      assert a.id in ids
      assert b.id in ids
    end

    test "a no-op removal broadcasts nothing", %{a: a, b: b} do
      assert {:ok, 0} = Dependencies.remove(a.id, b.id)
      refute_receive {:task_lifecycle, _, _}, 50
    end
  end

  # ---- readiness is unchanged --------------------------------------------

  describe "Issue.ready/1 is unaffected by non-gating edges" do
    test "only gating edges keep an issue out of ready", ctx do
      %{a: a, b: b} = ctx
      {:ok, a} = Ash.update(a, %{acceptance_waived: "n/a"}, action: :promote_to_ready)

      {:ok, _} = Dependencies.add(a.id, b.id, :relates_to)
      ready_ids = Issue.ready() |> Enum.map(& &1.id)
      assert a.id in ready_ids

      {:ok, _} = Dependencies.add(a.id, b.id, :depends_on)
      ready_ids = Issue.ready() |> Enum.map(& &1.id)
      refute a.id in ready_ids
    end
  end
end
