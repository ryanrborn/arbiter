defmodule Arbiter.Board.SnapshotLoadTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "snapshot-test-#{System.unique_integer([:positive])}",
        prefix: "snp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  describe "slots_total respects workspace-level max_concurrent" do
    test "uses workspace max when it's lower than system max", %{ws: ws} do
      # Set workspace max_concurrent to 2
      {:ok, ws} =
        Ash.update(ws, %{
          config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 2})
        })

      # Set system max to a higher value
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(4)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      # Load snapshot for this workspace
      snapshot = Snapshot.load(workspace_id: ws.id)

      # Should use the lower value (2)
      assert snapshot.slots_total == 2
    end

    test "uses system max when workspace max is not set", %{ws: ws} do
      # Don't set workspace max_concurrent
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(6)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      snapshot = Snapshot.load(workspace_id: ws.id)

      assert snapshot.slots_total == 6
    end

    test "uses workspace max when it's lower (system default)", %{ws: ws} do
      # Set workspace max_concurrent to 1
      {:ok, ws} =
        Ash.update(ws, %{
          config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 1})
        })

      # Don't override system max, use default
      snapshot = Snapshot.load(workspace_id: ws.id)

      # Should use the workspace limit (1) which is lower than system default (16)
      assert snapshot.slots_total == 1
    end

    test "no regression: uses system max when no workspace_id is passed" do
      # Set system max to a specific value
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(5)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      # Load snapshot without workspace_id (existing behavior)
      snapshot = Snapshot.load()

      # Should use the system max (5)
      assert snapshot.slots_total == 5
    end
  end

  # bd-38of5i: `derive/1` takes the `parent_of` pairs as an input; `load/1` is
  # the half that has to go and read them. Without this the board would render
  # a chip-less card for every child on a live install while the pure tests
  # stayed green.
  describe "parent refs are read from the dependency rows" do
    test "a child issue's card carries its parent's ref", %{ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "Parent epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "A child", workspace_id: ws.id})

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

      snapshot = Snapshot.load(workspace_id: ws.id)
      card = Enum.find(snapshot.backlog, &(&1.id == child.id))

      assert %{parent: %{id: parent_id, title: "Parent epic", issue_type: :epic}} = card
      assert parent_id == epic.id
      assert card.parent.child_total == 1
      assert card.parent.child_closed == 0
    end

    test "a closed epic does not reach the Closed column, but its child does", %{ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "Done epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "Done child", workspace_id: ws.id})

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Ash.update(child, %{close_upstream: false}, action: :close)
      {:ok, _} = Ash.update(epic, %{close_upstream: false}, action: :close)

      snapshot = Snapshot.load(workspace_id: ws.id)
      closed_ids = Enum.map(snapshot.closed_today, & &1.id)

      assert child.id in closed_ids
      refute epic.id in closed_ids
    end
  end
end
