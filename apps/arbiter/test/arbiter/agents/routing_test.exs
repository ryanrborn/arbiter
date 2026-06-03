defmodule Arbiter.Agents.RoutingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.{ByBudget, ByPriority, RoundRobin, Static}
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  describe "policy_for_workspace/1" do
    test "defaults to Static when workspace has no routing block" do
      ws = %Workspace{config: %{}}
      assert Routing.policy_for_workspace(ws) == Static
    end

    test "resolves `static`/`by_priority`/`by_budget`/`round_robin` strings" do
      for {policy_str, mod} <- [
            {"static", Static},
            {"by_priority", ByPriority},
            {"by_budget", ByBudget},
            {"round_robin", RoundRobin}
          ] do
        ws = %Workspace{config: %{"routing" => %{"policy" => policy_str}}}
        assert Routing.policy_for_workspace(ws) == mod
      end
    end

    test "falls back to Static for malformed / unknown policy strings" do
      ws = %Workspace{config: %{"routing" => %{"policy" => "magic"}}}
      assert Routing.policy_for_workspace(ws) == Static
    end

    test "nil workspace → Static" do
      assert Routing.policy_for_workspace(nil) == Static
    end
  end

  describe "Static policy" do
    test "returns the workspace `agent` config unchanged" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{"model" => "sonnet"}
          }
        }
      }

      bead = %Issue{priority: 2}
      assert Routing.choose(bead, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
    end

    test "nil workspace → default {:claude, %{}}" do
      bead = %Issue{priority: 2}
      assert Routing.choose(bead, nil, %{}) == %{type: :claude, config: %{}}
    end
  end

  describe "ByPriority policy" do
    setup do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{"model" => "sonnet"}
          },
          "routing" => %{
            "policy" => "by_priority",
            "rules" => %{
              "P0" => %{"model" => "opus"},
              "P1" => %{"model" => "opus"},
              "P4" => %{"model" => "haiku"}
            }
          }
        }
      }

      {:ok, ws: ws}
    end

    test "P0 routes to opus", %{ws: ws} do
      bead = %Issue{priority: 0}
      assert Routing.choose(bead, ws, %{}) == %{type: :claude, config: %{"model" => "opus"}}
    end

    test "P4 routes to haiku", %{ws: ws} do
      bead = %Issue{priority: 4}
      assert Routing.choose(bead, ws, %{}) == %{type: :claude, config: %{"model" => "haiku"}}
    end

    test "P2 (no rule) falls back to the workspace default", %{ws: ws} do
      bead = %Issue{priority: 2}
      assert Routing.choose(bead, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
    end

    test "rule overrides only the keys it specifies (default keys survive)" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{"model" => "sonnet", "tool_budget" => 100}
          },
          "routing" => %{
            "policy" => "by_priority",
            "rules" => %{"P0" => %{"model" => "opus"}}
          }
        }
      }

      bead = %Issue{priority: 0}

      assert Routing.choose(bead, ws, %{}) == %{
               type: :claude,
               config: %{"model" => "opus", "tool_budget" => 100}
             }
    end
  end

  describe "ByBudget policy" do
    setup do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{"model" => "sonnet"}
          },
          "routing" => %{
            "policy" => "by_budget",
            "budget_usd_per_day" => 5.0,
            "rules" => %{"P0" => %{"model" => "opus"}}
          }
        }
      }

      {:ok, ws: ws}
    end

    test "behaves like :by_priority below the budget", %{ws: ws} do
      bead = %Issue{priority: 0}
      assert Routing.choose(bead, ws, %{cost_usd_today: 0.10}) ==
               %{type: :claude, config: %{"model" => "opus"}}
    end

    test "degrades one tier when daily spend has crossed the budget", %{ws: ws} do
      bead = %Issue{priority: 0}
      assert Routing.choose(bead, ws, %{cost_usd_today: 9.99}) ==
               %{type: :claude, config: %{"model" => "sonnet"}}
    end

    test "treats an empty ledger snapshot as not-over-budget", %{ws: ws} do
      bead = %Issue{priority: 0}
      assert Routing.choose(bead, ws, %{}) ==
               %{type: :claude, config: %{"model" => "opus"}}
    end

    test "leaves the model alone when no model is set on the default config" do
      ws = %Workspace{
        config: %{
          "routing" => %{
            "policy" => "by_budget",
            "budget_usd_per_day" => 1.0
          }
        }
      }

      bead = %Issue{priority: 2}
      assert Routing.choose(bead, ws, %{cost_usd_today: 999.0}) ==
               %{type: :claude, config: %{}}
    end
  end

  describe "RoundRobin policy" do
    test "cycles through `routing.adapters` per dispatch" do
      ws = %Workspace{
        id: "ws-rr-test",
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
          "routing" => %{
            "policy" => "round_robin",
            "adapters" => [
              %{"model" => "opus"},
              %{"model" => "sonnet"},
              %{"model" => "haiku"}
            ]
          }
        }
      }

      bead = %Issue{priority: 2}

      first = Routing.choose(bead, ws, %{})
      second = Routing.choose(bead, ws, %{})
      third = Routing.choose(bead, ws, %{})
      fourth = Routing.choose(bead, ws, %{})

      assert first.config["model"] == "opus"
      assert second.config["model"] == "sonnet"
      assert third.config["model"] == "haiku"
      # Wraps back to the first entry.
      assert fourth.config["model"] == "opus"
    end

    test "falls back to the workspace default with an empty adapters list" do
      ws = %Workspace{
        id: "ws-rr-empty",
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
          "routing" => %{"policy" => "round_robin", "adapters" => []}
        }
      }

      bead = %Issue{priority: 2}
      assert Routing.choose(bead, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
    end
  end

  describe "valid_policies/0" do
    test "lists the four policies" do
      assert Enum.sort(Routing.valid_policies()) ==
               ["by_budget", "by_priority", "round_robin", "static"]
    end
  end
end
