defmodule GtElixir.Trackers.NoneTest do
  use ExUnit.Case, async: true

  alias GtElixir.Trackers.None

  describe "behaviour callbacks" do
    test "fetch/1 returns {:ok, %{}}" do
      assert None.fetch("anything") == {:ok, %{}}
    end

    test "transition/2 returns :ok for any status" do
      for status <- [:open, :in_progress, :closed] do
        assert None.transition("anything", status) == :ok
      end
    end

    test "update_fields/2 returns :ok regardless of fields" do
      assert None.update_fields("ref", %{title: "x"}) == :ok
      assert None.update_fields("ref", %{}) == :ok
    end

    test "link_for/1 returns an empty string" do
      assert None.link_for("ref") == ""
    end

    test "parse_ref/1 always returns :error (Tracker.None never owns a ref)" do
      assert None.parse_ref("VR-17585") == :error
      assert None.parse_ref("") == :error
    end

    test "list_transitions/1 returns all bead-vocabulary statuses" do
      assert {:ok, statuses} = None.list_transitions("ref")
      assert Enum.sort(statuses) == [:closed, :in_progress, :open]
    end
  end

  test "module declares the Tracker behaviour" do
    behaviours = None.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    assert GtElixir.Trackers.Tracker in behaviours
  end
end
