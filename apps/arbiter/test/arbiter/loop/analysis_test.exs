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
        terminal_lines: []
      },
      attrs
    )
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

  describe "small-sample caveat" do
    test "always carries the not-significant caveat" do
      report = Analysis.build_report([row(%{})], label: "test")
      assert Enum.any?(report.notes, &(&1 =~ "not statistically significant"))
    end
  end
end
