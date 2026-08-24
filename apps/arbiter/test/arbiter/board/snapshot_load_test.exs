defmodule Arbiter.Board.SnapshotLoadTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
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
end
