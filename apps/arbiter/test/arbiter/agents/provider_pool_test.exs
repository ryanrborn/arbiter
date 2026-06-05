defmodule Arbiter.Agents.ProviderPoolTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.ProviderPool

  setup do
    # The application already starts ProviderPool; just reset state between tests.
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  describe "healthy?/1" do
    test "returns true for an unknown provider (no entry)" do
      assert ProviderPool.healthy?(:claude)
      assert ProviderPool.healthy?(:gemini)
    end

    test "returns false while the cooldown is active" do
      ProviderPool.mark_exhausted(:claude)
      refute ProviderPool.healthy?(:claude)
    end

    test "returns true for other providers when one is exhausted" do
      ProviderPool.mark_exhausted(:claude)
      assert ProviderPool.healthy?(:gemini)
    end

    test "returns true after record_success clears the entry" do
      ProviderPool.mark_exhausted(:claude)
      refute ProviderPool.healthy?(:claude)
      ProviderPool.record_success(:claude)
      assert ProviderPool.healthy?(:claude)
    end
  end

  describe "mark_exhausted/1" do
    test "is idempotent — calling it again re-arms the cooldown" do
      ProviderPool.mark_exhausted(:claude)
      refute ProviderPool.healthy?(:claude)
      ProviderPool.mark_exhausted(:claude)
      refute ProviderPool.healthy?(:claude)
    end
  end

  describe "pick/1" do
    test "returns nil for an empty list" do
      assert ProviderPool.pick([]) == nil
    end

    test "returns the single entry for a one-element list" do
      assert ProviderPool.pick([:claude]) == :claude
    end

    test "returns the first healthy provider" do
      assert ProviderPool.pick([:claude, :gemini]) == :claude
    end

    test "skips exhausted providers and returns the next healthy one" do
      ProviderPool.mark_exhausted(:claude)
      assert ProviderPool.pick([:claude, :gemini]) == :gemini
    end

    test "falls back to the first provider when all are exhausted" do
      ProviderPool.mark_exhausted(:claude)
      ProviderPool.mark_exhausted(:gemini)
      assert ProviderPool.pick([:claude, :gemini]) == :claude
    end

    test "resumes primary provider after record_success" do
      ProviderPool.mark_exhausted(:claude)
      assert ProviderPool.pick([:claude, :gemini]) == :gemini
      ProviderPool.record_success(:claude)
      assert ProviderPool.pick([:claude, :gemini]) == :claude
    end
  end

  describe "cooldown_ms/0" do
    test "returns the configured value or the default (positive integer)" do
      ms = ProviderPool.cooldown_ms()
      assert is_integer(ms) and ms > 0
    end
  end
end
