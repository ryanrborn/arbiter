defmodule Arbiter.Agents.MultiProviderRoutingTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.Routing
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

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

  # bd-3hb4ih: the ReviewGate's print-timeout rotation needs the reviewer pool
  # in CONFIGURED order, not the single first-healthy answer
  # `reviewer_for_workspace/1` gives it — it has to know which entry to try next
  # once the current one has hit its CLI's own print-mode wall.
  describe "reviewer_pool/1" do
    test "returns review_agent.type as a list, in configured order" do
      ws = %Workspace{config: %{"review_agent" => %{"type" => ["gemini", "claude"]}}}

      assert Agents.reviewer_pool(ws) == [:gemini, :claude]
    end

    test "is NOT reordered by the circuit breaker (unlike reviewer_for_workspace/1)" do
      ProviderPool.mark_exhausted(:gemini)
      ws = %Workspace{config: %{"review_agent" => %{"type" => ["gemini", "claude"]}}}

      assert Agents.reviewer_pool(ws) == [:gemini, :claude]
      assert Agents.reviewer_for_workspace(ws) == Arbiter.Agents.Claude
    end

    test "a single string is a one-entry pool" do
      ws = %Workspace{config: %{"review_agent" => %{"type" => "gemini"}}}

      assert Agents.reviewer_pool(ws) == [:gemini]
    end

    test "falls back to the worker agent block when review_agent is absent" do
      ws = %Workspace{config: %{"agent" => %{"type" => ["codex", "claude"]}}}

      assert Agents.reviewer_pool(ws) == [:codex, :claude]
    end

    test "defaults to claude with neither block configured, and for a nil workspace" do
      assert Agents.reviewer_pool(%Workspace{config: %{}}) == [:claude]
      assert Agents.reviewer_pool(%Workspace{config: nil}) == [:claude]
      assert Agents.reviewer_pool(nil) == [:claude]
    end

    # `:error` is deliberately a type string whose ATOM certainly exists in the
    # VM — `String.to_existing_atom/1` alone would wave it through and hand
    # `for_type/1` something it raises on. The pool must filter against the
    # adapter registry, not merely against the atom table.
    test "drops type strings with no registered adapter, even when the atom exists" do
      ws = %Workspace{config: %{"review_agent" => %{"type" => ["error", "claude"]}}}

      assert Agents.reviewer_pool(ws) == [:claude]

      bare = %Workspace{config: %{"review_agent" => %{"type" => "error"}}}
      assert Agents.reviewer_pool(bare) == [:claude]
    end
  end
end
