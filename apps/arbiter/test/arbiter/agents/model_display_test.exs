defmodule Arbiter.Agents.ModelDisplayTest do
  use ExUnit.Case, async: true
  doctest Arbiter.Agents.ModelDisplay

  alias Arbiter.Agents.ModelDisplay

  describe "short/1" do
    test "maps Gemini model ids to Pro / Flash" do
      assert ModelDisplay.short("gemini-2.5-pro") == "Pro"
      assert ModelDisplay.short("gemini-2.5-pro-preview") == "Pro"
      assert ModelDisplay.short("gemini-2.5-flash") == "Flash"
      assert ModelDisplay.short("gemini-2.5-flash-lite") == "Flash"
    end

    test "maps Claude model ids to family names" do
      assert ModelDisplay.short("claude-opus-4-8") == "Opus"
      assert ModelDisplay.short("claude-sonnet-4-6") == "Sonnet"
      assert ModelDisplay.short("claude-haiku-4-5") == "Haiku"
    end

    test "maps the bare tier aliases the routing layer uses" do
      assert ModelDisplay.short("opus") == "Opus"
      assert ModelDisplay.short("sonnet") == "Sonnet"
      assert ModelDisplay.short("haiku") == "Haiku"
    end

    test "passes unrecognised ids through unchanged and nil through as nil" do
      assert ModelDisplay.short("some-other-model") == "some-other-model"
      assert ModelDisplay.short(nil) == nil
    end
  end
end
