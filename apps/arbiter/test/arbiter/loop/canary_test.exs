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
  alias Arbiter.Loop.{Canary, PendingWrite}
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

    test "the next tick after the kill switch ends the canary rather than pausing it", ctx do
      off = patch!(ctx.ws, %{}, ["loop.autonomous_routing_enabled"])

      assert {:ok, {:stopped, info}} = Canary.tick(off)
      assert info.proposal_id == ctx.row.id
      assert info.reason == :kill_switch

      stopped = Ash.get!(Workspace, ctx.ws.id)

      refute get_in(stopped.config, ["loop", "canary"]),
             "a canary the operator switched off must not stay in config to be resumed later"

      refute get_in(stopped.config, ["routing", "rules", "D2"]),
             "the kill switch must not land the canaried rule"

      # The proposal itself is untouched: the operator stopped the experiment,
      # they did not judge the proposal.
      assert Ash.get!(PendingWrite, ctx.row.id).state == :proposed

      # ...and it is one write, once.
      assert Canary.tick(stopped) == {:ok, :disabled}
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

  describe "candidate selection" do
    # `Loop.list_pending/1` filters on the `workspace_id` *column*, but
    # eligibility resolves the workspace from `payload["workspace_id"]`. When
    # the two disagree, the row can never start here — and if it were the only
    # candidate tried, one such row would wedge autonomy for the whole
    # workspace: every tick would error and no other proposal would be reached.
    test "a candidate whose payload names another workspace does not block the queue",
         %{ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{name: "other-ws", prefix: "ow", config: @routing_config})

      good = proposed!(ws)

      # Created last, so `list_pending/1` (created_at desc) hands it back first.
      poisoned =
        proposed!(ws, %{
          target: "routing.rules.D3",
          difficulty: 3,
          payload: %{
            "workspace_id" => other_ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D3" => %{"thinking" => "high"}}}}
          }
        })

      assert {:ok, %{workspace_id: other_id}} = Canary.eligible(poisoned)
      assert other_id == other_ws.id, "the poisoned row is eligible — just not here"

      assert {:ok, {:started, canary}} = ws |> enable!() |> Canary.tick(actor: "loop")

      assert canary.proposal_id == good.id,
             "the mismatched candidate must be skipped, not allowed to wedge the cycle"

      assert Ash.get!(PendingWrite, poisoned.id).state == :proposed
    end

    test "reports nothing_eligible when every candidate targets another workspace",
         %{ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{name: "other-ws-2", prefix: "o2", config: @routing_config})

      _poisoned =
        proposed!(ws, %{
          payload: %{
            "workspace_id" => other_ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D2" => @canaried_rule}}}
          }
        })

      enabled = enable!(ws)

      assert Canary.tick(enabled, actor: "loop") == {:ok, :nothing_eligible}
      refute get_in(Ash.get!(Workspace, ws.id).config, ["loop", "canary"])
    end
  end

  # bd-77cbif: standing_orders is never injected into a worker prompt (only
  # `arb prime`, the coordinator's briefing, reads it as text) — so it can't
  # "bloat every future prompt" the way skill bodies do. The moduledoc used
  # to make that claim for both; it must only make it for skills now.
  test "moduledoc no longer claims standing_orders bloats every prompt" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Canary)

    refute moduledoc =~ ~r/standing_orders.{0,80}bloat/s,
           "standing_orders is not injected into any prompt, so it cannot bloat one"
  end
end
