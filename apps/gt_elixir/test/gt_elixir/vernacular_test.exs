defmodule GtElixir.VernacularTest do
  use ExUnit.Case, async: true

  alias GtElixir.Beads.Workspace
  alias GtElixir.Vernacular

  setup do
    on_exit(fn -> Vernacular.clear() end)
    :ok
  end

  describe "label/1 with no active workspace" do
    test "returns gas-town defaults" do
      assert Vernacular.label(:worker) == "polecat"
      assert Vernacular.label(:coordinator) == "mayor"
      assert Vernacular.label(:merge_queue) == "refinery"
      assert Vernacular.label(:monitor) == "witness"
      assert Vernacular.label(:watchdog) == "deacon"
      assert Vernacular.label(:issue) == "bead"
      assert Vernacular.label(:batch) == "convoy"
      assert Vernacular.label(:rig) == "rig"
      assert Vernacular.label(:epic) == "mountain"
    end

    test "unknown key raises KeyError with the valid set in the message" do
      assert_raise KeyError, ~r/unknown vernacular key :nope/, fn ->
        Vernacular.label(:nope)
      end

      assert_raise KeyError, ~r/valid:/, fn -> Vernacular.label(:wat) end
    end
  end

  describe "label/1 with an active workspace overriding values" do
    setup do
      :ok =
        Vernacular.put_active(%{
          "vernacular" => %{"worker" => "Acolyte", "coordinator" => "Admiral"}
        })

      :ok
    end

    test "overridden key returns the workspace value" do
      assert Vernacular.label(:worker) == "Acolyte"
      assert Vernacular.label(:coordinator) == "Admiral"
    end

    test "non-overridden key falls back to the default" do
      assert Vernacular.label(:rig) == "rig"
      assert Vernacular.label(:issue) == "bead"
    end
  end

  describe "put_active/1 accepts Workspace struct, config map, or nil" do
    test "Workspace struct: reads its config" do
      ws = %Workspace{config: %{"vernacular" => %{"worker" => "Captain"}}}
      :ok = Vernacular.put_active(ws)
      assert Vernacular.label(:worker) == "Captain"
    end

    test "raw config map" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"worker" => "Sailor"}})
      assert Vernacular.label(:worker) == "Sailor"
    end

    test "nil clears" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"worker" => "X"}})
      assert Vernacular.label(:worker) == "X"
      :ok = Vernacular.put_active(nil)
      assert Vernacular.label(:worker) == "polecat"
    end

    test "empty/missing vernacular subkey is fine — everything falls back" do
      :ok = Vernacular.put_active(%{"tracker" => %{"type" => "none"}})
      assert Vernacular.label(:worker) == "polecat"
    end
  end

  describe "alias_resolve/1" do
    test "no active workspace → returns the verb verbatim (string-coerced)" do
      assert Vernacular.alias_resolve(:deploy) == "deploy"
      assert Vernacular.alias_resolve("ready") == "ready"
    end

    test "with aliases set, returns the alias" do
      :ok =
        Vernacular.put_active(%{
          "vernacular" => %{"aliases" => %{"deploy" => "sling", "ready" => "muster"}}
        })

      assert Vernacular.alias_resolve(:deploy) == "sling"
      assert Vernacular.alias_resolve("ready") == "muster"
    end

    test "unmapped verbs pass through unchanged" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"aliases" => %{"deploy" => "sling"}}})
      assert Vernacular.alias_resolve(:close) == "close"
    end

    test "blank alias value falls back to the verb" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"aliases" => %{"deploy" => ""}}})
      assert Vernacular.alias_resolve(:deploy) == "deploy"
    end
  end

  describe "emoji/1" do
    test "no active workspace → empty string for all keys" do
      assert Vernacular.emoji(:worker) == ""
      assert Vernacular.emoji(:issue) == ""
    end

    test "active emoji subkey returns the configured glyph" do
      :ok =
        Vernacular.put_active(%{
          "vernacular" => %{"emoji" => %{"worker" => "⚔️", "issue" => "📜"}}
        })

      assert Vernacular.emoji(:worker) == "⚔️"
      assert Vernacular.emoji(:issue) == "📜"
    end

    test "missing emoji for a known key returns empty string" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"emoji" => %{"worker" => "⚔️"}}})
      assert Vernacular.emoji(:rig) == ""
    end

    test "unknown key raises KeyError" do
      assert_raise KeyError, fn -> Vernacular.emoji(:bogus) end
    end
  end

  describe "process-dict scoping" do
    test "put_active in one process does not leak to another" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"worker" => "Captain"}})
      assert Vernacular.label(:worker) == "Captain"

      task = Task.async(fn -> Vernacular.label(:worker) end)
      assert Task.await(task) == "polecat"
    end

    test "clear/0 resets" do
      :ok = Vernacular.put_active(%{"vernacular" => %{"worker" => "X"}})
      :ok = Vernacular.clear()
      assert Vernacular.label(:worker) == "polecat"
    end
  end

  describe "introspection" do
    test "defaults/0 includes every advertised key" do
      defaults = Vernacular.defaults()
      assert is_map(defaults)
      assert defaults[:worker] == "polecat"
      assert MapSet.equal?(MapSet.new(Map.keys(defaults)), MapSet.new(Vernacular.keys()))
    end
  end
end
