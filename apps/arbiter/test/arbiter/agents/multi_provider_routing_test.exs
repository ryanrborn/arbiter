defmodule Arbiter.Agents.MultiProviderRoutingTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.Routing
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  describe "dispatch with agent.type as list" do
    test "picks the first provider when all are healthy" do
      ws = %Workspace{
        config: %{"agent" => %{"type" => ["claude", "gemini"], "config" => %{}}}
      }

      assert Routing.choose(%Issue{}, ws, %{}).type == :claude
    end

    test "falls back to gemini when claude is exhausted" do
      ProviderPool.mark_exhausted(:claude)

      ws = %Workspace{
        config: %{"agent" => %{"type" => ["claude", "gemini"], "config" => %{}}}
      }

      assert Routing.choose(%Issue{}, ws, %{}).type == :gemini
    end

    test "returns to claude after record_success clears the circuit breaker" do
      ProviderPool.mark_exhausted(:claude)
      ws = %Workspace{config: %{"agent" => %{"type" => ["claude", "gemini"], "config" => %{}}}}

      assert Routing.choose(%Issue{}, ws, %{}).type == :gemini

      ProviderPool.record_success(:claude)
      assert Routing.choose(%Issue{}, ws, %{}).type == :claude
    end

    test "degrades to first provider when all are exhausted" do
      ProviderPool.mark_exhausted(:claude)
      ProviderPool.mark_exhausted(:gemini)

      ws = %Workspace{
        config: %{"agent" => %{"type" => ["claude", "gemini"], "config" => %{}}}
      }

      assert Routing.choose(%Issue{}, ws, %{}).type == :claude
    end

    test "single-string type continues to work unchanged" do
      ws = %Workspace{
        config: %{"agent" => %{"type" => "claude", "config" => %{"model" => "opus"}}}
      }

      assert Routing.choose(%Issue{}, ws, %{}) == %{type: :claude, config: %{"model" => "opus"}}
    end

    test "list of one is equivalent to single string" do
      ws = %Workspace{
        config: %{"agent" => %{"type" => ["gemini"], "config" => %{}}}
      }

      assert Routing.choose(%Issue{}, ws, %{}).type == :gemini
    end

    test "by_difficulty policy respects pool when type is a list" do
      ProviderPool.mark_exhausted(:claude)

      ws = %Workspace{
        config: %{
          "agent" => %{"type" => ["claude", "gemini"], "config" => %{}},
          "routing" => %{"policy" => "by_difficulty"}
        }
      }

      choice = Routing.choose(%Issue{difficulty: 3}, ws, %{})
      assert choice.type == :gemini
      assert choice.config["model_tier"] == "premium"
    end
  end
end
