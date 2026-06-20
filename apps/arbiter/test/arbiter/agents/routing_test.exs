defmodule Arbiter.Agents.RoutingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.{ByBudget, ByDifficulty, ByPriority, RoundRobin, Static}
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  describe "policy_for_workspace/1" do
    test "defaults to Static when workspace has no routing block" do
      ws = %Workspace{config: %{}}
      assert Routing.policy_for_workspace(ws) == Static
    end

    test "resolves `static`/`by_priority`/`by_difficulty`/`by_budget`/`round_robin` strings" do
      for {policy_str, mod} <- [
            {"static", Static},
            {"by_priority", ByPriority},
            {"by_difficulty", ByDifficulty},
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

      task = %Issue{priority: 2}
      assert Routing.choose(task, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
    end

    test "nil workspace → default {:claude, %{}}" do
      task = %Issue{priority: 2}
      assert Routing.choose(task, nil, %{}) == %{type: :claude, config: %{}}
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
      task = %Issue{priority: 0}
      assert Routing.choose(task, ws, %{}) == %{type: :claude, config: %{"model" => "opus"}}
    end

    test "P4 routes to haiku", %{ws: ws} do
      task = %Issue{priority: 4}
      assert Routing.choose(task, ws, %{}) == %{type: :claude, config: %{"model" => "haiku"}}
    end

    test "P2 (no rule) falls back to the workspace default", %{ws: ws} do
      task = %Issue{priority: 2}
      assert Routing.choose(task, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
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

      task = %Issue{priority: 0}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model" => "opus", "tool_budget" => 100}
             }
    end
  end

  describe "ByDifficulty policy" do
    setup do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{}
          },
          "routing" => %{"policy" => "by_difficulty"}
        }
      }

      {:ok, ws: ws}
    end

    test "D0 → economy / none (default mapping)", %{ws: ws} do
      task = %Issue{difficulty: 0}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "economy", "thinking" => "none"}
             }
    end

    test "D1 → economy / low (default mapping)", %{ws: ws} do
      task = %Issue{difficulty: 1}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "economy", "thinking" => "low"}
             }
    end

    test "D2 → standard / medium (default mapping)", %{ws: ws} do
      task = %Issue{difficulty: 2}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "standard", "thinking" => "medium"}
             }
    end

    test "D3 → premium / high (default mapping)", %{ws: ws} do
      task = %Issue{difficulty: 3}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "premium", "thinking" => "high"}
             }
    end

    test "D4 → premium / high (default mapping)", %{ws: ws} do
      task = %Issue{difficulty: 4}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "premium", "thinking" => "high"}
             }
    end

    test "unset difficulty falls back to D2 (standard / medium)", %{ws: ws} do
      task = %Issue{difficulty: nil}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "standard", "thinking" => "medium"}
             }
    end

    test "workspace rule overrides only the keys it sets; defaults survive" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{}},
          "routing" => %{
            "policy" => "by_difficulty",
            "rules" => %{
              # Override only thinking for D3 — model_tier stays at the default.
              "D3" => %{"thinking" => "medium"}
            }
          }
        }
      }

      task = %Issue{difficulty: 3}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{"model_tier" => "premium", "thinking" => "medium"}
             }
    end

    test "workspace can pin a concrete model alongside tier/thinking" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{}},
          "routing" => %{
            "policy" => "by_difficulty",
            "rules" => %{
              "D4" => %{"model" => "opus", "thinking" => "high"}
            }
          }
        }
      }

      task = %Issue{difficulty: 4}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{
                 "model" => "opus",
                 "model_tier" => "premium",
                 "thinking" => "high"
               }
             }
    end

    test "rule keys merge on top of the workspace default agent config" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "type" => "claude",
            "config" => %{"tool_budget" => 100}
          },
          "routing" => %{"policy" => "by_difficulty"}
        }
      }

      task = %Issue{difficulty: 0}

      assert Routing.choose(task, ws, %{}) == %{
               type: :claude,
               config: %{
                 "tool_budget" => 100,
                 "model_tier" => "economy",
                 "thinking" => "none"
               }
             }
    end

    test "effective_difficulty/1 normalizes nil and out-of-range" do
      assert ByDifficulty.effective_difficulty(nil) == 2
      assert ByDifficulty.effective_difficulty(0) == 0
      assert ByDifficulty.effective_difficulty(4) == 4
      assert ByDifficulty.effective_difficulty(-1) == 0
      assert ByDifficulty.effective_difficulty(99) == 4
    end
  end

  describe "ByBudget policy (with :by_priority base, default)" do
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
      task = %Issue{priority: 0}

      assert Routing.choose(task, ws, %{cost_usd_today: 0.10}) ==
               %{type: :claude, config: %{"model" => "opus"}}
    end

    test "degrades one tier when daily spend has crossed the budget", %{ws: ws} do
      task = %Issue{priority: 0}

      assert Routing.choose(task, ws, %{cost_usd_today: 9.99}) ==
               %{type: :claude, config: %{"model" => "sonnet"}}
    end

    test "treats an empty ledger snapshot as not-over-budget", %{ws: ws} do
      task = %Issue{priority: 0}

      assert Routing.choose(task, ws, %{}) ==
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

      task = %Issue{priority: 2}

      assert Routing.choose(task, ws, %{cost_usd_today: 999.0}) ==
               %{type: :claude, config: %{}}
    end
  end

  describe "ByBudget policy (with :by_difficulty base)" do
    setup do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{}},
          "routing" => %{
            "policy" => "by_budget",
            "base_policy" => "by_difficulty",
            "budget_usd_per_day" => 5.0
          }
        }
      }

      {:ok, ws: ws}
    end

    test "below budget: passes through the difficulty default", %{ws: ws} do
      task = %Issue{difficulty: 3}

      assert Routing.choose(task, ws, %{cost_usd_today: 0.10}) == %{
               type: :claude,
               config: %{"model_tier" => "premium", "thinking" => "high"}
             }
    end

    test "over budget: degrades premium → standard", %{ws: ws} do
      task = %Issue{difficulty: 3}

      assert Routing.choose(task, ws, %{cost_usd_today: 9.99}) == %{
               type: :claude,
               config: %{"model_tier" => "standard", "thinking" => "high"}
             }
    end

    test "over budget: standard → economy", %{ws: ws} do
      task = %Issue{difficulty: 2}

      assert Routing.choose(task, ws, %{cost_usd_today: 9.99}) == %{
               type: :claude,
               config: %{"model_tier" => "economy", "thinking" => "medium"}
             }
    end

    test "over budget: economy stays at economy (floor)", %{ws: ws} do
      task = %Issue{difficulty: 0}

      assert Routing.choose(task, ws, %{cost_usd_today: 9.99}) == %{
               type: :claude,
               config: %{"model_tier" => "economy", "thinking" => "none"}
             }
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

      task = %Issue{priority: 2}

      first = Routing.choose(task, ws, %{})
      second = Routing.choose(task, ws, %{})
      third = Routing.choose(task, ws, %{})
      fourth = Routing.choose(task, ws, %{})

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

      task = %Issue{priority: 2}
      assert Routing.choose(task, ws, %{}) == %{type: :claude, config: %{"model" => "sonnet"}}
    end
  end

  describe "valid_policies/0" do
    test "lists the five policies" do
      assert Enum.sort(Routing.valid_policies()) ==
               ["by_budget", "by_difficulty", "by_priority", "round_robin", "static"]
    end
  end

  describe "agent_type_atom/1 with a list (pool dispatch, no exhaustion)" do
    test "picks first type in the list when all are healthy" do
      result = Routing.agent_type_atom(%{"type" => ["claude", "gemini"]})
      assert result == :claude
    end

    test "ignores unknown entries in the list and picks the first valid one" do
      result = Routing.agent_type_atom(%{"type" => ["claude"]})
      assert result == :claude
    end

    test "returns :claude when list is empty (fallback)" do
      result = Routing.agent_type_atom(%{"type" => []})
      assert result == :claude
    end
  end
end
