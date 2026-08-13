defmodule Arbiter.Loop.CanaryTest do
  @moduledoc """
  Stage 3 (bd-6edc0u, epic #1011): the *unit* semantics of the autonomous
  routing-tier canary — the opt-in flag, eligibility, arm assignment, the
  routing overlay, and the kill switch.

  The full apply → accumulate → verdict cycle lives in
  `Arbiter.Loop.CanaryCycleTest`.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Loop
  alias Arbiter.Loop.Canary
  alias Arbiter.Tasks.{Issue, Workspace}

  require Ash.Query

  @routing_config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  # The canaried tier is D2 (default: standard/medium) moved to premium/high,
  # so the two arms are observably different in every assertion below.
  @canaried_rule %{"model_tier" => "premium", "thinking" => "high"}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "canary-ws", prefix: "cy", config: @routing_config})

    %{ws: ws}
  end

  # A routing-tier proposal: a `:config_set` whose patch is exactly one D<n>
  # tier's model_tier/thinking adjustment.
  defp routing_candidate(ws, overrides) do
    Map.merge(
      %{
        kind: :config_set,
        gist: "D2 first-pass convergence is 41%: raise D2 to premium/high",
        category: "difficulty misestimate — D2 under-provisioned",
        target: "routing.rules.D2",
        difficulty: 2,
        repo: nil,
        scope: :fleet,
        target_metric: "first-pass ReviewGate convergence at D2",
        baseline: "41%",
        incident_refs: ["run-a", "run-b", "run-c"],
        task_refs: ["bd-1", "bd-2"],
        payload: %{
          "workspace_id" => ws.id,
          "patch" => %{"routing" => %{"rules" => %{"D2" => @canaried_rule}}}
        },
        origin: "loop.analyze",
        workspace_id: ws.id
      },
      overrides
    )
  end

  defp proposed!(ws, overrides \\ %{}) do
    {:ok, row} = Loop.record(routing_candidate(ws, overrides))
    row
  end

  defp patch!(ws, patch, unset \\ []) do
    {:ok, ws} =
      Ash.update(ws, %{patch: patch, unset_paths: unset}, action: :patch_config, actor: "test")

    ws
  end

  defp enable!(ws), do: patch!(ws, %{"loop" => %{"autonomous_routing_enabled" => true}})

  describe "the opt-in flag" do
    test "defaults to false on a workspace with no loop config", %{ws: ws} do
      refute Canary.enabled?(ws)
    end

    test "defaults to false when a loop block exists but the flag is unset", %{ws: ws} do
      ws = patch!(ws, %{"loop" => %{"evidence_bar" => %{"min_incidents" => 3}}})
      refute Canary.enabled?(ws)
    end

    test "is only true for the literal boolean true", %{ws: ws} do
      refute Canary.enabled?(%Workspace{
               config: %{"loop" => %{"autonomous_routing_enabled" => "true"}}
             })

      assert ws |> enable!() |> Canary.enabled?()
    end

    test "nil workspace is never enabled" do
      refute Canary.enabled?(nil)
    end
  end

  describe "eligibility" do
    test "accepts a routing-tier config_set that cleared the evidence bar", %{ws: ws} do
      row = proposed!(ws)
      assert row.state == :proposed

      assert {:ok, spec} = Canary.eligible(row)
      assert spec.difficulty == 2
      assert spec.rule == @canaried_rule
      assert spec.workspace_id == ws.id
    end

    test "refuses a proposal below the evidence bar", %{ws: ws} do
      row = proposed!(ws, %{incident_refs: ["run-a"], task_refs: ["bd-1"]})
      assert row.state == :hypothesis

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "proposed"
    end

    test "refuses a :task-scoped row that bypassed the bar", %{ws: ws} do
      row = proposed!(ws, %{scope: :task, incident_refs: ["run-a"], task_refs: ["bd-1"]})
      assert row.state == :proposed, "a :task-scoped row bypasses the bar by design"

      assert {:error, reason} = Canary.eligible(row)

      assert reason =~ "evidence",
             "autonomous application must re-check the bar, never inherit the :task bypass"
    end

    test "refuses a non-routing kind", %{ws: ws} do
      row = proposed!(ws, %{kind: :skill_patch, payload: %{"skill" => "x", "body" => "y"}})

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "routing"
    end

    test "refuses a config_set whose patch is not a routing rule", %{ws: ws} do
      row =
        proposed!(ws, %{
          target: "standing_orders",
          payload: %{"workspace_id" => ws.id, "patch" => %{"standing_orders" => "be careful"}}
        })

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "routing"
    end

    test "refuses a patch touching more than one tier", %{ws: ws} do
      row =
        proposed!(ws, %{
          target: "routing.rules.multi",
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{
              "routing" => %{
                "rules" => %{"D2" => %{"thinking" => "high"}, "D3" => %{"thinking" => "high"}}
              }
            }
          }
        })

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "one"
    end

    test "refuses a rule carrying keys other than model_tier/thinking", %{ws: ws} do
      row =
        proposed!(ws, %{
          target: "routing.rules.D2.model",
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D2" => %{"model" => "claude-opus-5"}}}}
          }
        })

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "model_tier"
    end

    test "refuses an unset_paths payload — a canary only ever sets a value", %{ws: ws} do
      row =
        proposed!(ws, %{
          target: "routing.rules.D2.unset",
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D2" => %{"thinking" => "high"}}}},
            "unset_paths" => ["routing.rules.D2.model_tier"]
          }
        })

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "unset"
    end

    test "refuses an already-applied row", %{ws: ws} do
      row = proposed!(ws)
      {:ok, applied} = Ash.update(row, %{state: :applied, actor: "op"}, action: :mark_applied)

      assert {:error, reason} = Canary.eligible(applied)
      assert reason =~ "proposed"
    end

    test "refuses a workspace whose routing policy is not by_difficulty" do
      {:ok, static_ws} =
        Ash.create(Workspace, %{
          name: "static-ws",
          prefix: "sw",
          config: %{"routing" => %{"policy" => "static"}}
        })

      row = proposed!(static_ws)

      assert {:error, reason} = Canary.eligible(row)
      assert reason =~ "by_difficulty"
    end
  end

  describe "arm assignment" do
    setup %{ws: ws} do
      row = proposed!(ws)
      {:ok, ws} = ws |> enable!() |> Canary.start(row, actor: "loop")
      %{ws: ws, row: row, canary: Canary.active(ws)}
    end

    test "is deterministic and splits tasks across both arms", %{canary: canary} do
      ids = for n <- 1..60, do: "bd-#{n}"
      arms = Enum.map(ids, &Canary.arm(canary, &1))

      assert :canary in arms
      assert :control in arms
      assert arms == Enum.map(ids, &Canary.arm(canary, &1)), "arm assignment must be stable"
    end

    test "a task's review runs land in the same arm as the task", %{canary: canary} do
      for n <- 1..20 do
        id = "bd-#{n}"
        assert Canary.arm(canary, id) == Canary.arm(canary, id <> "#review")
      end
    end
  end

  describe "the routing overlay" do
    setup %{ws: ws} do
      row = proposed!(ws)
      {:ok, ws} = ws |> enable!() |> Canary.start(row, actor: "loop")
      canary = Canary.active(ws)

      canary_id = Enum.find(1..200, &(Canary.arm(canary, "bd-#{&1}") == :canary))
      control_id = Enum.find(1..200, &(Canary.arm(canary, "bd-#{&1}") == :control))

      %{
        ws: ws,
        row: row,
        canary: canary,
        canary_id: "bd-#{canary_id}",
        control_id: "bd-#{control_id}"
      }
    end

    test "applies the canaried rule to the canary arm at the canaried tier", ctx do
      task = %Issue{id: ctx.canary_id, difficulty: 2}

      assert %{config: config} = Routing.choose(task, ctx.ws, %{})
      assert config == @canaried_rule
    end

    test "leaves the control arm on the unchanged rule", ctx do
      task = %Issue{id: ctx.control_id, difficulty: 2}

      assert %{config: config} = Routing.choose(task, ctx.ws, %{})
      assert config == ByDifficulty.default_mapping()[2]
    end

    test "leaves other difficulty tiers untouched in both arms", ctx do
      for id <- [ctx.canary_id, ctx.control_id], d <- [0, 1, 3, 4] do
        task = %Issue{id: id, difficulty: d}

        assert %{config: config} = Routing.choose(task, ctx.ws, %{})

        assert config == ByDifficulty.default_mapping()[d],
               "tier D#{d} must be untouched by a D2 canary"
      end
    end

    test "the kill switch takes effect mid-canary without unwinding config", ctx do
      off = patch!(ctx.ws, %{}, ["loop.autonomous_routing_enabled"])

      # The canary block is still on the workspace...
      assert get_in(off.config, ["loop", "canary"])
      # ...but it is inert the moment the flag is gone.
      refute Canary.active(off)

      task = %Issue{id: ctx.canary_id, difficulty: 2}

      assert %{config: config} = Routing.choose(task, off, %{})
      assert config == ByDifficulty.default_mapping()[2]
    end
  end

  describe "byte-for-byte default behaviour" do
    test "a workspace with no loop config routes exactly as before", %{ws: ws} do
      for d <- 0..4 do
        task = %Issue{id: "bd-#{d}", difficulty: d}

        assert Routing.choose(task, ws, %{}) == %{
                 type: :claude,
                 config: ByDifficulty.default_mapping()[d]
               }
      end
    end

    test "tick/2 is a no-op while the flag is unset", %{ws: ws} do
      _row = proposed!(ws)

      assert Canary.tick(ws) == {:ok, :disabled}
      assert {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config == @routing_config
    end
  end

  describe "start/3" do
    test "records the canary block and a paper-trail version tagged with the proposal",
         %{ws: ws} do
      row = proposed!(ws)
      enabled = enable!(ws)

      assert {:ok, started} = Canary.start(enabled, row, actor: "loop")

      block = get_in(started.config, ["loop", "canary"])
      assert block["proposal_id"] == row.id
      assert block["difficulty"] == 2
      assert block["rule"] == @canaried_rule
      assert block["min_dispatches"] == 20
      assert block["status"] == "running"
      assert block["started_at"]

      assert started.actor == "loop:proposal:#{row.id}"

      versions =
        Workspace.Version
        |> Ash.Query.filter(version_source_id == ^ws.id)
        |> Ash.read!()

      assert Enum.any?(versions, &(&1.actor == "loop:proposal:#{row.id}")),
             "the autonomous apply must be its own paper_trail version tagged with the proposal"
    end

    test "refuses to start a second canary while one is running", %{ws: ws} do
      row = proposed!(ws)
      {:ok, started} = ws |> enable!() |> Canary.start(row, actor: "loop")

      other =
        proposed!(ws, %{
          target: "routing.rules.D1",
          difficulty: 1,
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D1" => %{"model_tier" => "standard"}}}}
          }
        })

      assert {:error, reason} = Canary.start(started, other, actor: "loop")
      assert reason =~ "already"
    end

    test "refuses to start while the flag is unset", %{ws: ws} do
      row = proposed!(ws)

      assert {:error, reason} = Canary.start(ws, row, actor: "loop")
      assert reason =~ "autonomous_routing_enabled"
    end
  end
end
