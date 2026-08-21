defmodule Arbiter.Loop.AnalysisTest do
  # build_report/2 is pure over injected corpus rows — no DB needed.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.{Analysis, Report}

  # A corpus row is the enriched worker_run the pass reasons over. Defaults keep
  # the fixtures terse; each test overrides only what it cares about.
  defp row(attrs) do
    Map.merge(
      %{
        run_id: "run-#{System.unique_integer([:positive])}",
        task_id: "bd-x",
        repo: "arbiter",
        title: nil,
        worker_type: :main,
        status: :completed,
        model: "claude-sonnet-5",
        model_tier: "standard",
        difficulty: 2,
        difficulty_source: :at_dispatch,
        failure_reason: nil,
        cost_usd: 1.0,
        max_round: 1,
        rejected?: false,
        converged?: true,
        findings: [],
        terminal_lines: [],
        stop_category: nil
      },
      attrs
    )
  end

  # bd-apwfmy: the same c88c77b0 verdict, reached from the typed
  # `worker_runs.stop_category` with an EMPTY transcript. This is the
  # definition-of-done case — no tail regex, and the misclassification rate
  # still counts the run.
  describe "structured stop_category (no transcript)" do
    test "a context_thrash category reclassifies a rate-limited label with no transcript" do
      report =
        Analysis.build_report(
          [
            row(%{
              run_id: "run-typed",
              status: :failed,
              failure_reason: "agent was rate-limited / the API was overloaded",
              stop_category: "context_thrash",
              terminal_lines: []
            })
          ],
          label: "test"
        )

      seg = Enum.find(report.segmentation, fn s -> "run-typed" in s.run_ids end)
      assert seg.class == :agent_quality
      assert seg.subcategory == :context_exhaustion

      assert report.misclassification.corroborated == 1
      assert report.misclassification.reclassified == 1
    end

    test "a row with no stop_category key at all still classifies (older corpus shape)" do
      bare =
        row(%{status: :failed, failure_reason: "server restarted"}) |> Map.delete(:stop_category)

      report = Analysis.build_report([bare], label: "test")
      seg = hd(report.segmentation)
      assert seg.class == :operational
      assert seg.subcategory == :server_restart
    end
  end

  # ---- the c88c77b0 validation -------------------------------------------

  describe "context exhaustion mislabelled as rate-limited (c88c77b0)" do
    @c88 "c88c77b0-2927-41ec-b582-6210538a43b3"

    defp c88_row do
      row(%{
        run_id: @c88,
        task_id: "bd-dyfaq3",
        status: :failed,
        model: "claude-opus-4-8",
        difficulty: 3,
        failure_reason: "agent was rate-limited / the API was overloaded",
        cost_usd: 4.61,
        terminal_lines: [
          "Autocompact is thrashing: the context refilled to the limit within 3 turns of the previous compact, 3 times in a row.",
          "⚙ claude session error · 523.8s · $4.6105"
        ]
      })
    end

    test "is classified agent-quality/context_exhaustion, not operational" do
      report = Analysis.build_report([c88_row()], label: "test")

      seg =
        Enum.find(report.segmentation, fn s -> @c88 in s.run_ids end)

      assert seg.class == :agent_quality
      assert seg.subcategory == :context_exhaustion
    end

    test "is surfaced in the misclassification finding with its run_id and misleading label" do
      report = Analysis.build_report([c88_row()], label: "test")
      assert report.misclassification.reclassified == 1
      assert report.misclassification.corroborated == 1

      cite = hd(report.misclassification.citations)
      assert cite.run_id == @c88
      assert cite.failure_reason =~ "rate-limited"
      assert cite.corrected == :context_exhaustion

      # And it renders.
      md = Report.to_markdown(report)
      assert md =~ @c88
      assert md =~ "context_exhaustion"
    end

    test "a server-restart run is operational and NOT counted as a misclassification" do
      rows = [
        c88_row(),
        row(%{
          run_id: "restart-1",
          task_id: "bd-other",
          status: :failed,
          failure_reason: "server restarted",
          terminal_lines: ["⚙ server restarting for deploy", "worker will resume"]
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      # 2 corroborated failed runs, only 1 reclassified (the c88 one).
      assert report.misclassification.corroborated == 2
      assert report.misclassification.reclassified == 1

      restart_seg = Enum.find(report.segmentation, &("restart-1" in &1.run_ids))
      assert restart_seg.class == :operational
    end

    test "zero corroborated operational runs yield n/a rate, not 0.0%" do
      rows = [
        row(%{
          run_id: "agent-only-1",
          task_id: "bd-agent-only",
          status: :failed,
          failure_reason: ":review_gate_rejected",
          terminal_lines: ["VERDICT: request_changes"]
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      # No operational-labelled runs => zero-denominator.
      assert report.misclassification.corroborated == 0
      assert report.misclassification.reclassified == 0
      # Rate should be nil to signal zero-denominator in rendering.
      assert report.misclassification.rate == nil

      # And the misclassification rate section renders as "n/a (0 corroborated)".
      md = Report.to_markdown(report)
      assert md =~ "n/a (0 corroborated)"
      # Check that the specific section shows n/a, not 0.0%
      assert md =~ "misclassification rate of\n**n/a (0 corroborated)**"
    end
  end

  # ---- the bd-7rspia validation ------------------------------------------

  describe "difficulty misestimate on a single task (bd-7rspia)" do
    defp bd7_rows do
      [
        row(%{
          run_id: "5fe011e1",
          task_id: "bd-7rspia",
          status: :failed,
          model: "claude-haiku-4-5",
          model_tier: "economy",
          difficulty: 1,
          failure_reason: ":review_gate_rejected",
          cost_usd: 4.44,
          max_round: 2,
          rejected?: true,
          converged?: false,
          findings: [
            "Tests are green but the new code path is never executed at runtime — inert."
          ],
          terminal_lines: ["VERDICT: request_changes"]
        }),
        row(%{
          run_id: "3b2aa23a",
          task_id: "bd-7rspia",
          status: :completed,
          model: "claude-sonnet-5",
          model_tier: "standard",
          difficulty: 1,
          cost_usd: 6.18,
          max_round: 1,
          converged?: true
        })
      ]
    end

    test "flags bd-7rspia as a difficulty misestimate in its (difficulty, repo) cell" do
      report = Analysis.build_report(bd7_rows(), label: "test")
      m = Enum.find(report.difficulty_misestimates, &(&1.task_id == "bd-7rspia"))
      assert m
      assert m.cell == {1, "arbiter"}
      assert m.dispatched_difficulty == 1
      assert m.reason == :rework
      # Real cost is the sum across both attempts, not just the failed one.
      assert_in_delta m.cost_usd, 10.62, 0.001
    end

    test "surfaces the 'inert at runtime' finding category" do
      report = Analysis.build_report(bd7_rows(), label: "test")

      cat =
        Enum.find(report.finding_categories, fn c ->
          c.category =~ "inert at runtime"
        end)

      assert cat
      assert cat.incidents == 1
      assert cat.tasks == ["bd-7rspia"]
    end

    test "DECLINES a fleet-wide change on n=1 and recommends a per-task override" do
      report = Analysis.build_report(bd7_rows(), label: "test")

      sug =
        Enum.find(report.suggestions, fn s -> s.title =~ "inert at runtime" end)

      assert sug.verdict == :per_task_override
      assert sug.evidence.incidents == 1
      assert sug.evidence.tasks == 1

      md = Report.to_markdown(report)
      assert md =~ "per-task override"
      assert md =~ "decline"
      refute md =~ "**Fleet-wide** — 1 incident"
    end
  end

  describe "context-exhaustion is NOT a difficulty misestimate" do
    test "a task whose only failure was context-exhaustion is not flagged as a misestimate" do
      # Read-discipline, not difficulty — per the ticket's worked example. It is
      # surfaced as a finding category instead.
      rows = [
        row(%{
          run_id: @c88,
          task_id: "bd-dyfaq3",
          status: :failed,
          difficulty: 3,
          failure_reason: "agent was rate-limited / the API was overloaded",
          terminal_lines: ["Autocompact is thrashing", "⚙ claude session error"]
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      refute Enum.any?(report.difficulty_misestimates, &(&1.task_id == "bd-dyfaq3"))

      assert Enum.any?(report.finding_categories, &(&1.category =~ "context exhaustion"))
    end
  end

  describe "round-1 convergence with failed attempts is a distinct finding, not a rounds misestimate (vs-8i7rod)" do
    # vs-8i7rod: rounds: 1, 3 attempts, $5.59 total — reviewer approved on the
    # first round, but two of the three attempts failed for an agent-quality
    # reason before the third converged. The old predicate fired on
    # quality_failure? alone and reused the rounds-based "under-provisioned"
    # note/baseline even though rounds == 1. A cheap sibling task in the same
    # (difficulty, repo) cell gives it a cohort to be an outlier against.
    defp vs8i_rows do
      [
        row(%{
          run_id: "vs8i-1",
          task_id: "vs-8i7rod",
          repo: "arbiter",
          difficulty: 2,
          status: :failed,
          failure_reason: ":review_gate_rejected",
          cost_usd: 1.86,
          max_round: 1,
          rejected?: true,
          converged?: false,
          terminal_lines: ["VERDICT: request_changes"]
        }),
        row(%{
          run_id: "vs8i-2",
          task_id: "vs-8i7rod",
          repo: "arbiter",
          difficulty: 2,
          status: :failed,
          failure_reason: ":review_gate_rejected",
          cost_usd: 1.86,
          max_round: 1,
          rejected?: true,
          converged?: false,
          terminal_lines: ["VERDICT: request_changes"]
        }),
        row(%{
          run_id: "vs8i-3",
          task_id: "vs-8i7rod",
          repo: "arbiter",
          difficulty: 2,
          status: :completed,
          cost_usd: 1.87,
          max_round: 1,
          converged?: true
        })
      ]
    end

    defp cheap_cohort_row do
      row(%{
        run_id: "cheap-1",
        task_id: "vs-cheap",
        repo: "arbiter",
        difficulty: 2,
        status: :completed,
        cost_usd: 1.0,
        max_round: 1,
        converged?: true
      })
    end

    test "is not reported on the rounds-based path" do
      report = Analysis.build_report(vs8i_rows() ++ [cheap_cohort_row()], label: "test")
      m = Enum.find(report.difficulty_misestimates, &(&1.task_id == "vs-8i7rod"))
      assert m
      assert m.reason == :quality_failure
      assert m.rounds == 1
    end

    test "renders wording for the actual cause, not a fabricated rounds-based claim" do
      report = Analysis.build_report(vs8i_rows() ++ [cheap_cohort_row()], label: "test")
      m = Enum.find(report.difficulty_misestimates, &(&1.task_id == "vs-8i7rod"))

      refute m.note =~ "under-provisioned the actual work"
      refute m.note =~ ~r/needed 1 round/

      # No fabricated "0%" baseline — the reviewer approved on round 1, so a
      # round-1-approval-rate baseline of 0% would be false for this task.
      refute m.recommendation.baseline =~ "0%"
      assert_in_delta m.cost_usd, 5.59, 0.001
    end

    test "a task with no cohort in its cell to compare against is still flagged, with no fabricated baseline" do
      report = Analysis.build_report(vs8i_rows(), label: "test")
      m = Enum.find(report.difficulty_misestimates, &(&1.task_id == "vs-8i7rod"))
      assert m
      assert m.reason == :quality_failure
      refute m.recommendation.baseline =~ "0%"
    end
  end

  describe "cohort comparison: a task at or below its cell median is not flagged" do
    test "a reworked task that is no worse than its (difficulty, repo) cell peers is dropped" do
      rows = [
        # Target: rounds 2, cost 2.0 — reworked, but cheaper and faster than
        # its cohort peers below. Should not be flagged as it's below median on both.
        row(%{
          run_id: "cohort-target",
          task_id: "bd-cohort-target",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 2.0,
          max_round: 2
        }),
        # Cohort peer 1: rounds 2, cost 3.0 (median)
        row(%{
          run_id: "cohort-peer-1",
          task_id: "bd-cohort-peer-1",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 2
        }),
        # Cohort peer 2: rounds 3, cost 5.0 (above median on both)
        row(%{
          run_id: "cohort-peer-2",
          task_id: "bd-cohort-peer-2",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 5.0,
          max_round: 3
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      refute Enum.any?(report.difficulty_misestimates, &(&1.task_id == "bd-cohort-target"))
      assert Enum.any?(report.difficulty_misestimates, &(&1.task_id == "bd-cohort-peer-2"))
    end

    test "a reworked task above median on rounds but below median on cost is not flagged" do
      rows = [
        # Target: rounds 2 (above median), cost 2.0 (below median)
        row(%{
          run_id: "above-rounds-below-cost",
          task_id: "bd-above-rounds-below-cost",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 2.0,
          max_round: 2
        }),
        # Cohort peers: one at median, one above
        row(%{
          run_id: "at-median",
          task_id: "bd-at-median",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 1
        }),
        row(%{
          run_id: "above-both",
          task_id: "bd-above-both",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 5.0,
          max_round: 2
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      # Target is above on rounds but below on cost → should NOT be flagged
      refute Enum.any?(
               report.difficulty_misestimates,
               &(&1.task_id == "bd-above-rounds-below-cost")
             )
    end

    test "a task above median on cost but at/below median on rounds is not flagged" do
      rows = [
        # Target: rounds 1 (below median), cost 5.0 (above median)
        row(%{
          run_id: "below-rounds-above-cost",
          task_id: "bd-below-rounds-above-cost",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 5.0,
          max_round: 1
        }),
        # Cohort peers to establish medians
        row(%{
          run_id: "cohort1",
          task_id: "bd-cohort1",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 2
        }),
        row(%{
          run_id: "cohort2",
          task_id: "bd-cohort2",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 2
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      # Target is above on cost but below on rounds → should NOT be flagged
      refute Enum.any?(
               report.difficulty_misestimates,
               &(&1.task_id == "bd-below-rounds-above-cost")
             )
    end

    test "a task above median on both rounds and cost is flagged" do
      rows = [
        # Target: rounds 3 (above median), cost 5.0 (above median)
        row(%{
          run_id: "above-both",
          task_id: "bd-above-both",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 5.0,
          max_round: 3
        }),
        # Cohort peers to establish medians
        row(%{
          run_id: "cohort1",
          task_id: "bd-cohort1",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 1
        }),
        row(%{
          run_id: "cohort2",
          task_id: "bd-cohort2",
          repo: "verus",
          difficulty: 1,
          status: :completed,
          cost_usd: 3.0,
          max_round: 1
        })
      ]

      report = Analysis.build_report(rows, label: "test")
      # Target is above on both rounds and cost → SHOULD be flagged
      assert Enum.any?(report.difficulty_misestimates, &(&1.task_id == "bd-above-both"))
    end
  end

  describe "reviewer-finding incidents are counted per-task, not per-run" do
    test "two failed agent-quality runs of one task contribute one incident" do
      # Corpus keys the same task-level `findings` list to every run of a task
      # (review rounds are recorded under the base task id, not a run id). Two
      # failed agent-quality runs of the same task must count as ONE incident of
      # a given reviewer-finding category — not two — else the evidence line and
      # the categories table are inflated.
      finding = ["Tests are green but the new code path is never executed at runtime — inert."]

      rows = [
        row(%{
          run_id: "attempt-1",
          task_id: "bd-dup",
          status: :failed,
          failure_reason: ":review_gate_rejected",
          rejected?: true,
          converged?: false,
          max_round: 2,
          findings: finding,
          terminal_lines: ["VERDICT: request_changes"]
        }),
        row(%{
          run_id: "attempt-2",
          task_id: "bd-dup",
          status: :failed,
          failure_reason: ":review_gate_rejected",
          rejected?: true,
          converged?: false,
          max_round: 2,
          findings: finding,
          terminal_lines: ["VERDICT: request_changes"]
        })
      ]

      report = Analysis.build_report(rows, label: "test")

      cat = Enum.find(report.finding_categories, &(&1.category =~ "inert at runtime"))
      assert cat
      assert cat.incidents == 1
      assert cat.tasks == ["bd-dup"]
    end
  end

  # ---- the evidence bar --------------------------------------------------

  describe "evidence bar: >=3 incidents across >=2 tasks earns a fleet-wide suggestion" do
    test "3 context-exhaustion incidents across 2 tasks => fleet-wide read-discipline suggestion" do
      rows =
        for {task, i} <- [{"bd-a", 1}, {"bd-a", 2}, {"bd-b", 3}] do
          row(%{
            run_id: "ctx-#{i}",
            task_id: task,
            status: :failed,
            difficulty: 3,
            failure_reason: "agent was rate-limited / the API was overloaded",
            terminal_lines: ["Autocompact is thrashing", "⚙ claude session error"]
          })
        end

      report = Analysis.build_report(rows, label: "test")

      sug =
        Enum.find(report.suggestions, fn s ->
          s.verdict == :fleet_wide and s.title =~ "context"
        end)

      assert sug, "expected a fleet-wide suggestion for context exhaustion"
      assert sug.evidence.incidents >= 3
      assert sug.evidence.tasks >= 2
      assert sug.destination in [:skill, :repo_claude_md]
      assert is_binary(sug.target_metric)
      assert is_binary(sug.baseline)
    end
  end

  # ---- segmentation & cells ----------------------------------------------

  describe "operational failures are excluded from prompt-shaping" do
    test "operational runs never appear as an agent-quality suggestion or category" do
      rows =
        for i <- 1..5 do
          row(%{
            run_id: "op-#{i}",
            task_id: "bd-op-#{i}",
            status: :failed,
            failure_reason: "server restarted",
            terminal_lines: ["deploy restart"]
          })
        end

      report = Analysis.build_report(rows, label: "test")
      assert report.finding_categories == []
      assert report.suggestions == []
      # But they ARE reported in the operational segment.
      assert Enum.any?(report.segmentation, &(&1.class == :operational and &1.count == 5))
    end
  end

  describe "(difficulty, repo) cells" do
    test "computes rework rate and mean cost per cell" do
      rows = [
        row(%{task_id: "t1", difficulty: 2, repo: "arbiter", cost_usd: 4.0, max_round: 2}),
        row(%{task_id: "t2", difficulty: 2, repo: "arbiter", cost_usd: 6.0, max_round: 1}),
        row(%{task_id: "t3", difficulty: 1, repo: "verus", cost_usd: 2.0, max_round: 1})
      ]

      report = Analysis.build_report(rows, label: "test")
      cell = Enum.find(report.cells, &(&1.difficulty == 2 and &1.repo == "arbiter"))
      assert cell.tasks == 2
      assert_in_delta cell.rework_rate, 0.5, 0.001
      assert_in_delta cell.mean_cost_usd, 5.0, 0.001
    end
  end

  # #1221: the same unit of work re-filed as N separate tasks must not read as
  # N independent clean successes in the cost/rework cells — the real repro is
  # PRPatrol re-filing the same PR #3701 follow-up 5x on a ~3-minute tick.
  describe "duplicate dispatch (#1221)" do
    defp dup_dispatch_rows do
      titles_and_costs = [
        {"lt-6glz4n", 3.357},
        {"lt-bushr3", 1.135},
        {"lt-8za50u", 0.000},
        {"lt-3973ne", 1.561},
        {"lt-l52wk3", 0.000}
      ]

      for {task_id, cost} <- titles_and_costs do
        row(%{
          task_id: task_id,
          repo: "verus_server",
          difficulty: nil,
          title: "PR #3701: chore: merge integration/dolphin i…",
          cost_usd: cost,
          max_round: 1
        })
      end
    end

    test "collapses near-duplicate task filings into one unit in the cost/rework cell" do
      report = Analysis.build_report(dup_dispatch_rows(), label: "test")

      cell = Enum.find(report.cells, &(&1.repo == "verus_server"))
      assert cell
      # 5 re-filings of the same follow-up must not read as 5 independent
      # clean tasks — the cell should count them as (at most) one unit.
      assert cell.tasks == 1
      assert_in_delta cell.mean_cost_usd, 6.053, 0.001
      # A duplicate-dispatch cluster is itself a rework signal — 5 filings for
      # one unit of work is not a 0%-rework, healthy cell.
      assert cell.rework_rate > 0.0
    end

    test "a genuinely distinct task in the same repo is not folded into the cluster" do
      rows =
        dup_dispatch_rows() ++
          [
            row(%{
              task_id: "lt-unrelated",
              repo: "verus_server",
              difficulty: nil,
              title: "Fix unrelated flaky test in checkout flow",
              cost_usd: 2.0,
              max_round: 1
            })
          ]

      report = Analysis.build_report(rows, label: "test")
      cell = Enum.find(report.cells, &(&1.repo == "verus_server"))
      assert cell.tasks == 2
    end
  end

  # #1220: spawn failures happen after worker registration but before any
  # agent starts — no prompt, no model call, no transcript. They must land as
  # a distinct operational category, never :unclassified, and must not
  # starve/pollute the corpus-integrity denominator.
  describe "spawn failures (#1220)" do
    defp spawn_failure_rows do
      for {run_id, task_id} <- [
            {"dd64b9ae", "lt-1og9tl"},
            {"f816cfa3", "lt-dvllax"},
            {"bf11af00", "lt-2806jz"},
            {"27d9d2bf", "lt-b20dzw"}
          ] do
        row(%{
          run_id: run_id,
          task_id: task_id,
          repo: "verus-specs",
          status: :failed,
          failure_reason:
            "worker spawn failed after registration: {:inspect_worktree_failed, " <>
              "{:fetch_failed, \"git fetch origin development failed in " <>
              "/home/rborn/dev/leotech/verus-specs: fatal: couldn't find remote ref development\"}}",
          terminal_lines: []
        })
      end
    end

    test "all four are segmented as operational/spawn_failure, not unclassified" do
      report = Analysis.build_report(spawn_failure_rows(), label: "test")

      refute Enum.any?(report.segmentation, &(&1.class == :unknown))

      spawn_seg =
        Enum.find(
          report.segmentation,
          &(&1.class == :operational and &1.subcategory == :spawn_failure)
        )

      assert spawn_seg
      assert spawn_seg.count == 4
    end

    test "spawn failures have no transcript, so they are excluded from the corpus-integrity denominator" do
      report = Analysis.build_report(spawn_failure_rows(), label: "test")

      assert report.misclassification.corroborated == 0
      assert report.misclassification.reclassified == 0
      assert report.misclassification.rate == nil
    end

    test "renders as its own operational subcategory in the markdown report" do
      report = Analysis.build_report(spawn_failure_rows(), label: "test")
      md = Report.to_markdown(report)

      assert md =~ "spawn_failure"
      refute md =~ "unclassified"
    end
  end

  describe "small-sample caveat" do
    test "always carries the not-significant caveat" do
      report = Analysis.build_report([row(%{})], label: "test")
      assert Enum.any?(report.notes, &(&1 =~ "not statistically significant"))
    end
  end
end
