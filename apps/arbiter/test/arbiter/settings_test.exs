defmodule Arbiter.SettingsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings

  describe "conductor_system_max_concurrent/0" do
    test "returns nil when no override has been set" do
      assert Settings.conductor_system_max_concurrent() == nil
    end

    test "returns the persisted override after it is set" do
      assert {:ok, 7} = Settings.set_conductor_system_max_concurrent(7)
      assert Settings.conductor_system_max_concurrent() == 7
    end
  end

  describe "set_conductor_system_max_concurrent/1" do
    test "creates the singleton row on first write" do
      assert {:ok, 4} = Settings.set_conductor_system_max_concurrent(4)
      assert Settings.conductor_system_max_concurrent() == 4
    end

    test "updates the existing singleton row on subsequent writes (no duplicate rows)" do
      assert {:ok, 4} = Settings.set_conductor_system_max_concurrent(4)
      assert {:ok, 9} = Settings.set_conductor_system_max_concurrent(9)
      assert Settings.conductor_system_max_concurrent() == 9

      assert {:ok, [_single_row]} = Ash.read(Arbiter.Settings.Installation)
    end

    test "nil clears the override" do
      assert {:ok, 4} = Settings.set_conductor_system_max_concurrent(4)
      assert {:ok, nil} = Settings.set_conductor_system_max_concurrent(nil)
      assert Settings.conductor_system_max_concurrent() == nil
    end

    test "rejects zero/negative integers" do
      assert {:error, :invalid_value} = Settings.set_conductor_system_max_concurrent(0)
      assert {:error, :invalid_value} = Settings.set_conductor_system_max_concurrent(-1)
    end
  end
end
