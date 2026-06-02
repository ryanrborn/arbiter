defmodule Arbiter.BrandingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Beads.Workspace
  alias Arbiter.Branding

  setup do
    on_exit(fn -> Branding.clear() end)
    :ok
  end

  describe "get/1 with no active branding" do
    test "returns the neutral defaults" do
      assert Branding.get(:name) == "Arbiter"
      assert Branding.get(:mark) == "/images/arbiter-mark.png"
      assert Branding.get(:wordmark) == "/images/arbiter-wordmark.png"
      assert Branding.get(:favicon) == "/favicon.ico"
      assert Branding.get(:accent) == nil
    end

    test "unknown key raises KeyError with the valid set in the message" do
      assert_raise KeyError, ~r/unknown branding key :nope/, fn ->
        Branding.get(:nope)
      end

      assert_raise KeyError, ~r/valid:/, fn -> Branding.get(:wat) end
    end
  end

  describe "get/1 with active branding overriding values" do
    setup do
      :ok =
        Branding.put_active(%{
          "branding" => %{
            "name" => "Penumbral Arbiter",
            "wordmark" => "/images/eclipse-wordmark.png",
            "accent" => "oklch(58% 0.233 277.117)"
          }
        })

      :ok
    end

    test "overridden key returns the configured value" do
      assert Branding.get(:name) == "Penumbral Arbiter"
      assert Branding.get(:wordmark) == "/images/eclipse-wordmark.png"
      assert Branding.get(:accent) == "oklch(58% 0.233 277.117)"
    end

    test "non-overridden key falls back to the default" do
      assert Branding.get(:mark) == "/images/arbiter-mark.png"
      assert Branding.get(:favicon) == "/favicon.ico"
    end
  end

  describe "put_active/1 accepts Workspace struct, config map, or nil" do
    test "Workspace struct: reads its config" do
      ws = %Workspace{config: %{"branding" => %{"name" => "Covenant"}}}
      :ok = Branding.put_active(ws)
      assert Branding.get(:name) == "Covenant"
    end

    test "raw config map" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "Grimoire"}})
      assert Branding.get(:name) == "Grimoire"
    end

    test "nil clears" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "X"}})
      assert Branding.get(:name) == "X"
      :ok = Branding.put_active(nil)
      assert Branding.get(:name) == "Arbiter"
    end

    test "empty/missing branding subkey is fine — everything falls back" do
      :ok = Branding.put_active(%{"vernacular" => %{"worker" => "Acolyte"}})
      assert Branding.get(:name) == "Arbiter"
    end

    test "blank string value falls back to the default" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "", "wordmark" => ""}})
      assert Branding.get(:name) == "Arbiter"
      assert Branding.get(:wordmark) == "/images/arbiter-wordmark.png"
    end
  end

  describe "all/0" do
    test "with no active branding, returns every key at its default" do
      assert Branding.all() == Branding.defaults()
    end

    test "merges overrides over defaults" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "Eclipse"}})

      all = Branding.all()
      assert all.name == "Eclipse"
      assert all.mark == "/images/arbiter-mark.png"
      assert MapSet.equal?(MapSet.new(Map.keys(all)), MapSet.new(Branding.keys()))
    end
  end

  describe "process-dict scoping" do
    test "put_active in one process does not leak to another" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "Covenant"}})
      assert Branding.get(:name) == "Covenant"

      task = Task.async(fn -> Branding.get(:name) end)
      assert Task.await(task) == "Arbiter"
    end

    test "clear/0 resets" do
      :ok = Branding.put_active(%{"branding" => %{"name" => "X"}})
      :ok = Branding.clear()
      assert Branding.get(:name) == "Arbiter"
    end
  end

  describe "introspection" do
    test "defaults/0 keys match keys/0" do
      defaults = Branding.defaults()
      assert is_map(defaults)
      assert defaults[:name] == "Arbiter"
      assert MapSet.equal?(MapSet.new(Map.keys(defaults)), MapSet.new(Branding.keys()))
    end
  end
end
