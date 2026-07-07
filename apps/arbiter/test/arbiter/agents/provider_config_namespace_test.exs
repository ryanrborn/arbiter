defmodule Arbiter.Agents.ProviderConfigNamespaceTest do
  @moduledoc """
  Regression coverage for bd-a6vu3c: `agent.config` is shared across every
  provider in a multi-provider pool. A `tier_models` (or `thinking_argv`)
  override intended for one provider must not leak into another adapter's
  tier resolution.

  The fix lets a workspace nest overrides under the provider's own name
  (`agent.config.codex.tier_models`); each adapter merges only its own
  sub-map over the flat/shared keys, so a Codex-scoped override reaches
  Codex alone while flat keys stay backward-compatible.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.Gemini

  setup do
    on_exit(fn ->
      Claude.Config.clear()
      Codex.Config.clear()
      Gemini.Config.clear()
    end)

    :ok
  end

  describe "provider-scoped tier_models do not leak across a shared pool" do
    test "a codex-scoped tier_models override reaches Codex but not Claude/Gemini" do
      # The exact bd-a6vu3c incident: an override meant for Codex, applied to
      # a workspace whose pool also serves Claude and Gemini.
      config = %{
        "codex" => %{
          "tier_models" => %{
            "economy" => "gpt-5.4-mini",
            "standard" => "gpt-5.5",
            "premium" => "gpt-5.5"
          }
        }
      }

      Codex.Config.put_active(config)
      Claude.Config.put_active(config)
      Gemini.Config.put_active(config)

      # Codex sees its scoped override.
      assert Codex.Config.model_for_tier("standard") == "gpt-5.5"

      # Claude and Gemini fall back to their own built-in defaults — the Codex
      # model name must never reach them.
      assert Claude.Config.model_for_tier("standard") ==
               Claude.Config.default_tier_models()["standard"]

      assert Gemini.Config.model_for_tier("standard") ==
               Gemini.Config.default_tier_models()["standard"]

      refute Claude.Config.model_for_tier("standard") == "gpt-5.5"
      refute Gemini.Config.model_for_tier("standard") == "gpt-5.5"
    end

    test "each provider reads only its own namespaced override" do
      config = %{
        "codex" => %{"tier_models" => %{"standard" => "gpt-5-codex"}},
        "claude" => %{"tier_models" => %{"standard" => "opus"}},
        "gemini" => %{"tier_models" => %{"standard" => "gemini-2.5-pro"}}
      }

      Codex.Config.put_active(config)
      Claude.Config.put_active(config)
      Gemini.Config.put_active(config)

      assert Codex.Config.model_for_tier("standard") == "gpt-5-codex"
      assert Claude.Config.model_for_tier("standard") == "opus"
      assert Gemini.Config.model_for_tier("standard") == "gemini-2.5-pro"
    end

    test "flat tier_models still applies to every provider (backward compat)" do
      config = %{"tier_models" => %{"standard" => "shared-model"}}

      Codex.Config.put_active(config)
      Claude.Config.put_active(config)
      Gemini.Config.put_active(config)

      assert Codex.Config.model_for_tier("standard") == "shared-model"
      assert Claude.Config.model_for_tier("standard") == "shared-model"
      assert Gemini.Config.model_for_tier("standard") == "shared-model"
    end

    test "a provider-scoped override wins over the flat/shared key for that provider only" do
      config = %{
        "tier_models" => %{"standard" => "shared-model"},
        "codex" => %{"tier_models" => %{"standard" => "gpt-5-codex"}}
      }

      Codex.Config.put_active(config)
      Claude.Config.put_active(config)

      # Codex prefers its own scoped map...
      assert Codex.Config.model_for_tier("standard") == "gpt-5-codex"
      # ...while Claude still reads the flat/shared key (no claude sub-map).
      assert Claude.Config.model_for_tier("standard") == "shared-model"
    end

    test "a provider tier_models sub-map wholly owns that provider's mapping" do
      # When a provider scopes tier_models, its sub-map replaces the flat key
      # for that provider (shallow merge). Tiers it omits fall back to the
      # provider's own built-in default — NOT to the flat/shared map — so a
      # provider's tier resolution never mixes in another provider's models.
      config = %{
        "tier_models" => %{"economy" => "shared-economy", "standard" => "shared-standard"},
        "codex" => %{"tier_models" => %{"standard" => "gpt-5-codex"}}
      }

      Codex.Config.put_active(config)

      # standard comes from the codex sub-map...
      assert Codex.Config.model_for_tier("standard") == "gpt-5-codex"
      # ...economy is absent from it, so it falls back to Codex's built-in
      # default rather than the flat/shared "shared-economy".
      assert Codex.Config.model_for_tier("economy") ==
               Codex.Config.default_tier_models()["economy"]
    end
  end

  describe "provider-scoped thinking_argv do not leak across a shared pool" do
    test "a claude-scoped thinking_argv override reaches Claude but not Gemini" do
      config = %{
        "claude" => %{"thinking_argv" => %{"high" => ["--effort", "max"]}}
      }

      Claude.Config.put_active(config)
      Gemini.Config.put_active(config)

      assert Claude.Config.thinking_argv("high") == ["--effort", "max"]
      # Gemini has no scoped override and its built-in default is empty.
      assert Gemini.Config.thinking_argv("high") == []
    end
  end
end
