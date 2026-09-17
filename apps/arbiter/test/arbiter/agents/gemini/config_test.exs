defmodule Arbiter.Agents.Gemini.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini.Config

  setup do
    on_exit(fn -> Config.clear() end)
    :ok
  end

  describe "put_active/1 and resolve/0" do
    test "seeds and resolves active configuration" do
      Config.put_active(%{"model" => "flash-3.5", "credentials_ref" => "literal-key"})

      assert {:ok, cfg} = Config.resolve()
      assert cfg.model == "flash-3.5"
      assert cfg.credentials_ref == "literal-key"
    end
  end

  describe "resolve_api_key/0" do
    test "resolves env variable" do
      System.put_env("TEST_GEMINI_KEY", "env-secret")
      on_exit(fn -> System.delete_env("TEST_GEMINI_KEY") end)

      Config.put_active(%{"credentials_ref" => "env:TEST_GEMINI_KEY"})
      assert Config.resolve_api_key() == "env-secret"
    end

    test "resolves literal token" do
      Config.put_active(%{"credentials_ref" => "literal-token"})
      assert Config.resolve_api_key() == "literal-token"
    end

    test "falls back to ambient env variable if not configured" do
      System.put_env("GEMINI_API_KEY", "ambient-secret")
      on_exit(fn -> System.delete_env("GEMINI_API_KEY") end)

      Config.put_active(%{})
      assert Config.resolve_api_key() == "ambient-secret"
    end

    test "rotates through api_keys non-empty list" do
      System.put_env("ROT1", "val1")
      System.put_env("ROT2", "val2")

      on_exit(fn ->
        System.delete_env("ROT1")
        System.delete_env("ROT2")
      end)

      Config.put_active(%{"api_keys" => ["env:ROT1", "env:ROT2"]})

      assert Config.resolve_api_key() == "val1"
      assert Config.resolve_api_key() == "val2"
      assert Config.resolve_api_key() == "val1"
    end
  end

  describe "model_for_tier/2 (bd-d2yut8: agy-scoped tier map)" do
    test "defaults to the upstream-gemini tier map when no executable is given" do
      assert Config.model_for_tier("economy") == "gemini-2.5-flash-lite"
      assert Config.model_for_tier("standard") == "gemini-2.5-flash"
      assert Config.model_for_tier("premium") == "gemini-2.5-pro"
    end

    test "the upstream-gemini branch is unchanged when explicitly requested" do
      assert Config.model_for_tier("economy", :gemini) == "gemini-2.5-flash-lite"
      assert Config.model_for_tier("standard", :gemini) == "gemini-2.5-flash"
      assert Config.model_for_tier("premium", :gemini) == "gemini-2.5-pro"
    end

    test "resolves the agy-scoped tier map for the :agy executable" do
      assert Config.model_for_tier("economy", :agy) == "gemini-3.8-flash-low"
      assert Config.model_for_tier("standard", :agy) == "gemini-3.8-flash-medium"
      assert Config.model_for_tier("premium", :agy) == "gemini-3.1-pro-high"
      assert Config.model_for_tier("flagship", :agy) == "claude-opus-4-6-thinking"
    end

    test "an unknown tier returns nil for either executable" do
      assert Config.model_for_tier("nonexistent", :agy) == nil
      assert Config.model_for_tier("nonexistent", :gemini) == nil
    end
  end

  describe "default_tier_models/1" do
    test "returns the gemini map by default" do
      assert Config.default_tier_models() == Config.default_tier_models(:gemini)
      assert Config.default_tier_models(:gemini)["premium"] == "gemini-2.5-pro"
    end

    test "returns the agy map with a flagship tier" do
      assert Config.default_tier_models(:agy) == %{
               "economy" => "gemini-3.8-flash-low",
               "standard" => "gemini-3.8-flash-medium",
               "premium" => "gemini-3.1-pro-high",
               "flagship" => "claude-opus-4-6-thinking"
             }
    end
  end

  describe "thinking_argv/2 for :agy (bd-d2yut8: --effort mapping)" do
    test "low/medium/high map to --effort <level>" do
      assert Config.thinking_argv("low", :agy) == ["--effort", "low"]
      assert Config.thinking_argv("medium", :agy) == ["--effort", "medium"]
      assert Config.thinking_argv("high", :agy) == ["--effort", "high"]
    end

    test "none and nil map to no argv" do
      assert Config.thinking_argv("none", :agy) == []
      assert Config.thinking_argv(nil, :agy) == []
    end

    test "xhigh/max clamp to --effort high" do
      assert Config.thinking_argv("xhigh", :agy) == ["--effort", "high"]
      assert Config.thinking_argv("max", :agy) == ["--effort", "high"]
    end
  end

  describe "thinking_argv/2 for :gemini (Finding 1: upstream CLI rejects --effort)" do
    test "always returns [] regardless of level, including the default (no executable given)" do
      for level <- ["low", "medium", "high", "xhigh", "max", "none", nil] do
        assert Config.thinking_argv(level) == []
        assert Config.thinking_argv(level, :gemini) == []
      end
    end

    test "a workspace thinking_argv override does not leak onto the gemini branch" do
      Config.put_active(%{"thinking_argv" => %{"high" => ["--effort", "high"]}})
      assert Config.thinking_argv("high", :gemini) == []
    end
  end
end
