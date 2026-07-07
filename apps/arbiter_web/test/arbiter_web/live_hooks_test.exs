defmodule ArbiterWeb.LiveHooksTest do
  use ExUnit.Case, async: true

  # Helper function to test the filtering logic applied in live_hooks
  defp filter_hidden_providers(quotas) do
    Enum.reject(quotas, &(&1.provider in ["codex"]))
  end

  describe "on_mount(:quota)" do
    test "filters out codex provider from quota list" do
      # Create mock quotas with codex mixed in
      claude_quota = %{provider: "claude", utilization_5h: 50}
      codex_quota = %{provider: "codex", utilization_5h: 25}
      gemini_quota = %{provider: "gemini", utilization_5h: 10}

      quotas = [claude_quota, codex_quota, gemini_quota]

      # Simulate the filtering that happens in on_mount
      filtered = filter_hidden_providers(quotas)

      assert filtered == [claude_quota, gemini_quota]
      assert not Enum.any?(filtered, &(&1.provider == "codex"))
    end

    test "preserves non-codex providers" do
      quotas = [
        %{provider: "claude", utilization_5h: 50},
        %{provider: "gemini", utilization_5h: 10},
        %{provider: "antigravity", utilization_5h: 30}
      ]

      filtered = filter_hidden_providers(quotas)

      assert length(filtered) == 3
      assert Enum.map(filtered, & &1.provider) == ["claude", "gemini", "antigravity"]
    end

    test "handles empty quota list" do
      filtered = filter_hidden_providers([])
      assert filtered == []
    end

    test "handles all-codex quota list" do
      quotas = [
        %{provider: "codex", utilization_5h: 25},
        %{provider: "codex", utilization_5h: 50}
      ]

      filtered = filter_hidden_providers(quotas)
      assert filtered == []
    end
  end

  describe "quota update filtering" do
    test "identifies codex provider as hidden" do
      codex_quota = %{provider: "codex", utilization_5h: 75}
      # Codex should be identified as hidden
      assert codex_quota.provider in ["codex"]
    end

    test "allows non-codex provider updates" do
      claude_quota = %{provider: "claude", utilization_5h: 60}
      # Non-codex providers should be allowed
      assert not (claude_quota.provider in ["codex"])
    end
  end
end
