defmodule Arbiter.Loop.CanaryCycleTest do
  @moduledoc """
  Stage 3 (bd-6edc0u, epic #1011): the full autonomous canary cycle —
  apply → accumulate ≥ 20 canary-arm dispatches → verdict.

  Two scenarios are simulated over real `worker_runs` / `review_gate_rounds` /
  `usage_events` rows: one where the canaried tier's first-pass convergence
  *improves* and one where it *regresses*. The revert must fire in the
  regression case and only there.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Loop
  alias Arbiter.Loop.{Canary, CanaryTicker, PendingWrite}
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  require Ash.Query

  @routing_config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  @canaried_rule %{"model_tier" => "premium", "thinking" => "high"}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "canary-cycle-ws", prefix: "cc", config: @routing_config})

    {:ok, row} =
      Loop.record(%{
        kind: :config_set,
        gist: "D2 first-pass convergence is 41%: raise D2 to premium/high",
        category: "difficulty misestimate — D2 under-provisioned",
        target: "routing.rules.D2",
        difficulty: 2,
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
      })

    {:ok, ws} =
      Ash.update(ws, %{patch: %{"loop" => %{"autonomous_routing_enabled" => true}}},
        action: :patch_config,
        actor: "operator"
      )

    %{ws: ws, proposal: row}
  end

  # ---- seeding ------------------------------------------------------------

  # `worker_runs.task_id` is a free string with no FK, and the canary reads the
  # dispatched tier off `difficulty_at_dispatch`, so a simulated dispatch needs
  # no `Issue` row — which is what lets the test choose task ids and therefore
  # arms deterministically (`Issue` ids are generated, not accepted).
  defp seed_dispatch!(ws, task_id, opts) do
    difficulty = Keyword.get(opts, :difficulty, 2)
    converged? = Keyword.fetch!(opts, :converged)
    rounds = if converged?, do: 1, else: Keyword.get(opts, :rounds, 2)

    {:ok, run} =
      Ash.create(Run, %{
        task_id: task_id,
        repo: "arbiter",
        workspace_id: ws.id,
        worker_type: :main,
        status: :completed,
        model: "claude-sonnet-5",
        difficulty_at_dispatch: difficulty,
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Event, %{
        task_id: task_id,
        step: :work,
        worker_run_id: run.id,
        cost_usd: Keyword.get(opts, :cost, 1.0),
        occurred_at: DateTime.utc_now()
      })

    for round <- 1..rounds do
      {:ok, _} =
        Ash.create(Round, %{
          task_id: task_id,
          round: round,
          role: :review,
          verdict: if(round == rounds and converged?, do: :approve, else: :request_changes),
          converged: round == rounds and converged?
        })
    end

    run
  end

  # Seed `n` dispatches into the given arm, `converged_n` of which converge on
  # the first review round. Task ids are drawn from a wide pool and filtered by
  # the canary's own arm function, so the seeded data lands in the arm the
  # routing overlay would actually have placed it in.
  defp seed_arm!(ws, canary, arm, n, converged_n, prefix) do
    ids =
      1..5000
      |> Stream.map(&"#{prefix}-#{&1}")
      |> Stream.filter(&(Canary.arm(canary, &1) == arm))
      |> Enum.take(n)

    assert length(ids) == n

    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, idx} ->
      seed_dispatch!(ws, id, converged: idx < converged_n)
    end)

    ids
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  defp patch!(ws, patch, unset \\ []) do
    {:ok, ws} =
      Ash.update(ws, %{patch: patch, unset_paths: unset},
        action: :patch_config,
        actor: "operator"
      )

    ws
  end

  defp enable!(ws), do: patch!(ws, %{"loop" => %{"autonomous_routing_enabled" => true}})

  defp disable!(ws), do: patch!(ws, %{}, ["loop.autonomous_routing_enabled"])

  # Backdate a running canary's `started_at`. Nothing else about it changes —
  # the point is a canary that has been live for `days` without gathering its
  # sample, which is otherwise a multi-day thing to observe.
  defp age_canary!(ws, days) do
    started =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    patch!(ws, %{"loop" => %{"canary" => %{"started_at" => started}}})
  end

  # Poll a condition rather than sleeping a fixed span: the assertion below is
  # about the ticker's *timer* firing at all, not about how fast it does.
  defp eventually(fun, attempts \\ 150) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  # ---- the cycle ----------------------------------------------------------

  describe "a full canary cycle" do
    test "holds its verdict until the canary arm has ≥ 20 dispatches", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      # 19 canary-arm dispatches, all regressed — still not enough to judge.
      seed_arm!(ws, canary, :canary, 19, 0, "can")
      seed_arm!(ws, canary, :control, 20, 20, "con")

      assert {:insufficient_data, stats} = Canary.evaluate(ws)
      assert stats.canary.dispatches == 19
      assert stats.min_dispatches == 20

      assert {:ok, {:running, _}} = Canary.tick(ws)

      assert get_in(reload!(ws).config, ["loop", "canary", "status"]) == "running",
             "a canary must not be judged before its sample size is met"

      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :proposed
    end

    test "reverts automatically when first-pass convergence regresses", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      # canary: 5/20 first-pass. control: 16/20. A clear regression.
      seed_arm!(ws, canary, :canary, 20, 5, "can")
      seed_arm!(ws, canary, :control, 20, 16, "con")

      assert {:revert, stats} = Canary.evaluate(ws)
      assert stats.canary.dispatches == 20
      assert_in_delta stats.canary.first_pass_convergence, 0.25, 0.001
      assert_in_delta stats.control.first_pass_convergence, 0.8, 0.001

      assert {:ok, {:reverted, _stats}} = Canary.tick(ws)

      reverted = reload!(ws)

      refute get_in(reverted.config, ["loop", "canary"]),
             "the reverted canary block must be gone from config"

      refute get_in(reverted.config, ["routing", "rules", "D2"]),
             "a reverted canary must never leave its rule behind fleet-wide"

      # Routing is back on the untouched default for every task.
      for id <- ["can-1", "con-1"] do
        assert %{config: config} = Routing.choose(%Issue{id: id, difficulty: 2}, reverted, %{})
        assert config == ByDifficulty.default_mapping()[2]
      end

      # The proposal is closed out, soft, with the measurement attached.
      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :rejected
      assert row.rejection_reason =~ "convergence"
      assert row.outcome_delta["verdict"] == "revert"
      assert row.outcome_checked_at

      # And the revert is its own paper-trail version, tagged with the proposal.
      versions =
        Workspace.Version
        |> Ash.Query.filter(version_source_id == ^ws.id)
        |> Ash.read!()

      tagged = Enum.filter(versions, &(&1.actor == "loop:proposal:#{ctx.proposal.id}"))

      assert length(tagged) >= 2,
             "both the autonomous apply and the auto-revert must be attributed versions"
    end

    test "promotes the rule when first-pass convergence improves", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      # canary: 18/20 first-pass. control: 10/20. A clear improvement.
      seed_arm!(ws, canary, :canary, 20, 18, "can")
      seed_arm!(ws, canary, :control, 20, 10, "con")

      assert {:promote, stats} = Canary.evaluate(ws)
      assert_in_delta stats.canary.first_pass_convergence, 0.9, 0.001
      assert_in_delta stats.control.first_pass_convergence, 0.5, 0.001

      assert {:ok, {:promoted, _stats}} = Canary.tick(ws)

      promoted = reload!(ws)

      refute get_in(promoted.config, ["loop", "canary"]),
             "a finished canary must not stay in config"

      assert get_in(promoted.config, ["routing", "rules", "D2"]) == @canaried_rule,
             "a passing canary lands its rule on the workspace's routing rules"

      # Both arms now route the same way — the canary split is over.
      for id <- ["can-1", "con-1"] do
        assert %{config: config} = Routing.choose(%Issue{id: id, difficulty: 2}, promoted, %{})
        assert config == @canaried_rule
      end

      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :applied
      assert row.applied_at
      assert row.outcome_delta["verdict"] == "promote"
    end

    test "an equal-convergence canary is not a regression", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 12, "can")
      seed_arm!(ws, canary, :control, 20, 12, "con")

      assert {:promote, _stats} = Canary.evaluate(ws)
    end

    test "only the canaried tier's dispatches count toward the sample", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 10, 0, "can")
      seed_arm!(ws, canary, :control, 20, 20, "con")

      # 20 more canary-arm dispatches, but at D4 — a different tier entirely.
      1..5000
      |> Stream.map(&"d4-#{&1}")
      |> Stream.filter(&(Canary.arm(canary, &1) == :canary))
      |> Enum.take(20)
      |> Enum.each(&seed_dispatch!(ws, &1, converged: true, difficulty: 4))

      assert {:insufficient_data, stats} = Canary.evaluate(ws)
      assert stats.canary.dispatches == 10
    end

    test "an operator's rejection mid-canary outranks a passing canary", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      # Convergence the canary would happily promote on — 20/20 vs 0/20.
      seed_arm!(ws, canary, :canary, 20, 20, "can")
      seed_arm!(ws, canary, :control, 20, 0, "con")

      {:ok, _} = Loop.reject_pending(ctx.proposal, reason: "not this one", actor: "operator")

      assert {:ok, {:abandoned, _}} = Canary.tick(reload!(ws))

      stopped = reload!(ws)
      refute get_in(stopped.config, ["loop", "canary"])

      refute get_in(stopped.config, ["routing", "rules", "D2"]),
             "an operator's rejection must outrank a passing canary"

      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :rejected
    end

    test "the kill switch stops the cycle mid-canary", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 0, "can")
      seed_arm!(ws, canary, :control, 20, 20, "con")

      off = disable!(ws)

      # The canary is ended, not paused — and no verdict was reached on it,
      # even though the seeded data is a textbook regression.
      assert {:ok, {:stopped, %{reason: :kill_switch}}} = Canary.tick(off)
      refute get_in(reload!(ws).config, ["loop", "canary"])

      # Nothing was auto-applied or auto-reverted behind the operator's back,
      # and routing is already back on the baseline (see CanaryTest).
      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :proposed
    end

    # The dispatches that accumulate while the flag is off are baseline in
    # *both* arms — the overlay returned `nil` for every one of them. If the
    # canary block survived the kill switch, re-arming the flag would judge that
    # window, find the arms identical (they were), and read the tie as a pass.
    test "re-enabling after the kill switch never promotes on the stale window", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)
      started_at = get_in(reload!(ws).config, ["loop", "canary", "started_at"])

      seed_arm!(ws, canary, :canary, 3, 3, "early")

      # Kill switch, then a long quiet stretch of un-canaried dispatches: both
      # arms sit at exactly the same convergence, which is what a comparison
      # that never actually ran looks like.
      off = disable!(ws)
      assert {:ok, {:stopped, _}} = Canary.tick(off)

      off = reload!(ws)
      seed_arm!(off, canary, :canary, 25, 12, "after")
      seed_arm!(off, canary, :control, 25, 12, "afterc")

      # ...and the operator arms it again.
      on = enable!(off)

      assert {:ok, {:started, fresh}} = Canary.tick(on)

      assert fresh.proposal_id == ctx.proposal.id
      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :proposed

      refute get_in(reload!(ws).config, ["routing", "rules", "D2"]),
             "a window the canary spent switched off must never promote the rule"

      # The clean canary measures from *now*, not from the original start.
      assert get_in(reload!(ws).config, ["loop", "canary", "started_at"]) > started_at

      # And with the old dispatches out of the window, there is nothing to judge
      # yet — exactly as if the canary had just begun, which it has.
      assert {:ok, {:running, stats}} = Canary.tick(reload!(ws))
      assert stats.canary.dispatches == 0
    end

    # A tier too quiet to reach `min_dispatches` must not keep an unvalidated
    # rule live on half its dispatches forever.
    test "a canary that never gathers its sample expires instead of running forever", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 4, 4, "can")

      aged = age_canary!(ws, 15)

      assert {:ok, {:expired, info}} = Canary.tick(aged)
      assert info.proposal_id == ctx.proposal.id
      assert info.age_days >= 14
      assert info.max_age_days == 14

      expired = reload!(ws)
      refute get_in(expired.config, ["loop", "canary"])

      refute get_in(expired.config, ["routing", "rules", "D2"]),
             "an expired canary must never land its unjudged rule"

      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :rejected
      assert row.rejection_reason =~ "expired"
      assert row.outcome_delta["verdict"] == "expired"
    end

    test "a canary still inside its deadline is left to run", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 4, 4, "can")

      aged = age_canary!(ws, 13)

      assert {:ok, {:running, _stats}} = Canary.tick(aged)
      assert get_in(reload!(ws).config, ["loop", "canary", "status"]) == "running"
      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :proposed
    end
  end

  # `Arbiter.Worker.ReviewGate.record_round/5` writes the implementer's revise
  # pass into `review_gate_rounds` too, with the same task id and round number
  # as the review it answers. Counting those as review rounds would understate
  # cost/round in the operator's escalation mail and in the proposal's
  # `outcome_delta`.
  describe "the measurement" do
    test "implementer revise rows are not counted as review rounds", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      # 10 tasks converge on round 1, 10 take two review rounds: 30 review
      # rounds, at $1 per dispatch.
      canary_ids = seed_arm!(ws, canary, :canary, 20, 10, "can")
      seed_arm!(ws, canary, :control, 20, 10, "con")

      # Every non-converging task also has an implementer revise row.
      for {id, idx} <- Enum.with_index(canary_ids), idx >= 10 do
        {:ok, _} = Ash.create(Round, %{task_id: id, round: 1, role: :impl, converged: false})
      end

      {_verdict, stats} = Canary.evaluate(ws)

      assert stats.canary.review_rounds == 30,
             "only :review rows are review rounds — :impl rows share the task id and round"

      assert_in_delta stats.canary.cost_per_round, 20.0 / 30.0, 0.0001
      assert_in_delta stats.canary.first_pass_convergence, 0.5, 0.001
    end
  end

  # The acceptance criterion is that a regression is taken back with *no
  # operator action*. Every test above still has a human in the loop — it is
  # the one calling `tick/2`. This one does not: the ticker's own timer is the
  # only thing that runs, which is what makes the revert automatic rather than
  # a chore with a nicer name.
  describe "the revert is automatic" do
    test "the ticker's own timer reverts a regressing canary unattended", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 2, "can")
      seed_arm!(ws, canary, :control, 20, 18, "con")

      # Note: no `poll/1` call anywhere below.
      start_supervised!({CanaryTicker, name: nil, enabled: true, interval_ms: 25})

      assert eventually(fn -> is_nil(get_in(reload!(ws).config, ["loop", "canary"])) end),
             "a regressing canary must be reverted by the ticker's timer alone"

      reverted = reload!(ws)

      refute get_in(reverted.config, ["routing", "rules", "D2"]),
             "an unattended revert must not leave the canaried rule behind"

      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :rejected
    end
  end

  describe "tick/2 as the driver" do
    test "starts a canary for an eligible proposal when none is running", ctx do
      assert {:ok, {:started, canary}} = Canary.tick(ctx.ws)
      assert canary.proposal_id == ctx.proposal.id

      started = reload!(ctx.ws)
      assert get_in(started.config, ["loop", "canary", "proposal_id"]) == ctx.proposal.id
    end

    test "does nothing when no proposal is eligible", %{ws: ws, proposal: proposal} do
      {:ok, _} = Loop.reject_pending(proposal, reason: "not this one", actor: "operator")

      assert Canary.tick(ws) == {:ok, :nothing_eligible}
      refute get_in(reload!(ws).config, ["loop", "canary"])
    end
  end
end
