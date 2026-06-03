defmodule Arbiter.Agents.RoutingTest do
  @moduledoc """
  Unit-tests the Phase A model-tiering policy. The module is pure (no DB,
  no processes) — we exercise it directly with hand-rolled structs.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Agents.Routing
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  defp bead(priority \\ 2), do: %Issue{id: "bd-tst", priority: priority}
  defp workspace(config \\ %{}), do: %Workspace{config: config}

  describe "choose_work_model/3 — fallback chain" do
    test "nil workspace, no override → nil (caller uses CLI default)" do
      assert Routing.choose_work_model(bead(), nil) == nil
    end

    test "workspace with no agent key → nil" do
      assert Routing.choose_work_model(bead(), workspace()) == nil
    end

    test "agent.config.model is the static fallback" do
      ws = workspace(%{"agent" => %{"config" => %{"model" => "sonnet"}}})
      assert Routing.choose_work_model(bead(), ws) == "sonnet"
    end

    test "override wins over workspace config" do
      ws = workspace(%{"agent" => %{"config" => %{"model" => "sonnet"}}})
      assert Routing.choose_work_model(bead(), ws, override: "opus") == "opus"
    end

    test "blank-string override is treated as no override" do
      ws = workspace(%{"agent" => %{"config" => %{"model" => "sonnet"}}})
      assert Routing.choose_work_model(bead(), ws, override: "") == "sonnet"
      assert Routing.choose_work_model(bead(), ws, override: nil) == "sonnet"
    end
  end

  describe "choose_work_model/3 — by_priority policy" do
    test "uses workspace rules when present" do
      ws =
        workspace(%{
          "agent" => %{
            "config" => %{"model" => "sonnet"},
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{
                "P0" => "opus",
                "P4" => "haiku"
              }
            }
          }
        })

      assert Routing.choose_work_model(%Issue{priority: 0}, ws) == "opus"
      assert Routing.choose_work_model(%Issue{priority: 4}, ws) == "haiku"
      # P2 has no rule → falls back to static model.
      assert Routing.choose_work_model(%Issue{priority: 2}, ws) == "sonnet"
    end

    test "uses default_priority_rules when policy is by_priority but rules unset" do
      ws =
        workspace(%{
          "agent" => %{
            "routing" => %{"policy" => "by_priority"}
          }
        })

      # default rules map P0/P1 → opus, P2/P3 → sonnet, P4 → haiku.
      assert Routing.choose_work_model(%Issue{priority: 0}, ws) == "opus"
      assert Routing.choose_work_model(%Issue{priority: 2}, ws) == "sonnet"
      assert Routing.choose_work_model(%Issue{priority: 4}, ws) == "haiku"
    end

    test "accepts the {priority => %{\"model\" => ...}} map shape from the design doc" do
      ws =
        workspace(%{
          "agent" => %{
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{
                "P0" => %{"model" => "opus"},
                "P4" => %{"model" => "haiku"}
              }
            }
          }
        })

      assert Routing.choose_work_model(%Issue{priority: 0}, ws) == "opus"
      assert Routing.choose_work_model(%Issue{priority: 4}, ws) == "haiku"
    end

    test "override beats by_priority just like it beats static" do
      ws =
        workspace(%{
          "agent" => %{"routing" => %{"policy" => "by_priority"}}
        })

      assert Routing.choose_work_model(%Issue{priority: 0}, ws, override: "haiku") == "haiku"
    end

    test "unknown policy strings degrade to static" do
      ws =
        workspace(%{
          "agent" => %{
            "config" => %{"model" => "sonnet"},
            "routing" => %{"policy" => "by_round_robin"}
          }
        })

      assert Routing.choose_work_model(%Issue{priority: 0}, ws) == "sonnet"
    end
  end

  describe "choose_review_model/3" do
    test "uses review_agent.config.model when set" do
      ws =
        workspace(%{
          "agent" => %{
            "config" => %{"model" => "sonnet"},
            "review_agent" => %{"config" => %{"model" => "opus"}}
          }
        })

      assert Routing.choose_review_model(bead(), ws) == "opus"
      # Worker still on sonnet — asymmetry, the design doc's headline use case.
      assert Routing.choose_work_model(bead(), ws) == "sonnet"
    end

    test "falls back to the work model when review_agent.model is not set" do
      ws = workspace(%{"agent" => %{"config" => %{"model" => "sonnet"}}})
      assert Routing.choose_review_model(bead(), ws) == "sonnet"
    end

    test "override wins" do
      ws =
        workspace(%{
          "agent" => %{"review_agent" => %{"config" => %{"model" => "opus"}}}
        })

      assert Routing.choose_review_model(bead(), ws, override: "haiku") == "haiku"
    end

    test "with no agent config at all → nil" do
      assert Routing.choose_review_model(bead(), workspace()) == nil
      assert Routing.choose_review_model(bead(), nil) == nil
    end
  end

  describe "reversibility" do
    test "an empty agent config map flips back to the CLI default" do
      ws = workspace(%{"agent" => %{}})
      assert Routing.choose_work_model(bead(), ws) == nil
      assert Routing.choose_review_model(bead(), ws) == nil
    end
  end
end
