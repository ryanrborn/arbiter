defmodule Arbiter.Loop.ReportTest do
  # Pure rendering — no DB.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Report

  # A representative struct that exercises every disciplined element the report
  # must render. Built by hand here so the renderer is tested in isolation from
  # the Analysis that populates it.
  defp sample do
    %Report{
      window: %{
        label: "last 7d",
        since: ~U[2026-07-22 00:00:00Z],
        until: ~U[2026-07-29 00:00:00Z]
      },
      totals: %{runs: 60, main_runs: 40, failed: 18, completed: 42, tasks: 30, dispatches: 40},
      segmentation: [
        %{class: :operational, subcategory: :server_restart, count: 10, run_ids: ["op1", "op2"]},
        %{
          class: :agent_quality,
          subcategory: :context_exhaustion,
          count: 3,
          run_ids: [
            "c88c77b0-2927-41ec-b582-6210538a43b3",
            "aq2",
            "aq3"
          ]
        },
        %{class: :agent_quality, subcategory: :review_gate_rejected, count: 4, run_ids: ["r1"]}
      ],
      misclassification: %{
        corroborated: 12,
        reclassified: 1,
        rate: 1 / 12,
        citations: [
          %{
            run_id: "c88c77b0-2927-41ec-b582-6210538a43b3",
            failure_reason: "agent was rate-limited / the API was overloaded",
            corrected: :context_exhaustion
          }
        ]
      },
      finding_categories: [
        %{
          category: "plausible code, green tests, inert at runtime",
          incidents: 1,
          tasks: ["bd-7rspia"],
          run_ids: ["5fe011e1"],
          example: "ReviewGate rejected over 2 rounds; code never executed the new path"
        }
      ],
      difficulty_misestimates: [
        %{
          task_id: "bd-7rspia",
          cell: {1, "arbiter"},
          dispatched_difficulty: 1,
          rounds: 2,
          cost_usd: 10.62,
          note: "D1→economy→Haiku green but inert; refiled D2→Sonnet approved round 1",
          recommendation: %{
            destination: :per_task_override,
            action: "set Issue.difficulty=2 on bd-7rspia; log tracked hypothesis",
            target_metric: "round-1 approval rate",
            baseline: "0% for this task's first attempt"
          }
        }
      ],
      cells: [
        %{difficulty: 1, repo: "arbiter", tasks: 8, rework_rate: 0.25, mean_cost_usd: 3.1},
        %{difficulty: 2, repo: "arbiter", tasks: 6, rework_rate: 0.5, mean_cost_usd: 6.4}
      ],
      suggestions: [
        %{
          title: "Add read-discipline reminder for large-corpus analysis tasks",
          target_metric: "context-exhaustion failures per week",
          baseline: "3 this window",
          destination: :skill,
          evidence: %{incidents: 3, tasks: 2},
          verdict: :fleet_wide,
          rationale: "3 incidents across 2 tasks clears the evidence bar"
        }
      ],
      notes: ["At ~15 dispatches/day most single-window deltas are not significant."]
    }
  end

  describe "to_markdown/1" do
    setup do
      %{md: Report.to_markdown(sample())}
    end

    test "states the window and the sample counts up front", %{md: md} do
      assert md =~ "last 7d"
      assert md =~ "40" and md =~ "dispatch"
      assert md =~ "failed"
    end

    test "renders the operational vs agent-quality segmentation with counts", %{md: md} do
      assert md =~ "Operational"
      assert md =~ "Agent-quality"
      assert md =~ "server_restart"
      assert md =~ "context_exhaustion"
    end

    test "misclassification is a first-class finding, citing the run_id", %{md: md} do
      assert md =~ "isclassif" or md =~ "corpus-integrity" or md =~ "corpus integrity"
      assert md =~ "c88c77b0-2927-41ec-b582-6210538a43b3"
      # The corrected class must be named.
      assert md =~ "context_exhaustion"
    end

    test "the c88c77b0 citation shows the misleading label it corrected", %{md: md} do
      assert md =~ "rate-limited"
    end

    test "difficulty misestimates are segmented by (difficulty, repo) cell", %{md: md} do
      assert md =~ "bd-7rspia"
      # The (difficulty, repo) cell is shown.
      assert md =~ "(1, arbiter)" or md =~ "D1" or md =~ "difficulty 1"
    end

    test "every suggestion carries target metric, baseline and a destination", %{md: md} do
      assert md =~ "context-exhaustion failures per week"
      assert md =~ "3 this window"
      # destination is one of skill / repo CLAUDE.md / per-task override
      assert md =~ "skill"
    end

    test "a fleet-wide suggestion states its evidence: incidents across tasks", %{md: md} do
      assert md =~ "3 incidents" or md =~ "3 incident"
      assert md =~ "2 task"
    end

    test "renders (difficulty, repo) cell table with rework rate and mean cost", %{md: md} do
      assert md =~ "rework"
      assert md =~ "50.0%"
    end

    test "carries the small-sample caveat verbatim", %{md: md} do
      assert md =~ "not significant" or md =~ "not be significant"
    end
  end

  describe "unclassified runs are surfaced as corpus-integrity signals" do
    test "unclassified (unknown) runs are shown with their run_ids in segmentation" do
      report = %Report{
        window: %{label: "test"},
        totals: %{runs: 3, main_runs: 3, failed: 3, completed: 0, tasks: 3, dispatches: 3},
        segmentation: [
          %{class: :unknown, subcategory: :unclassified, count: 2, run_ids: ["unk-1", "unk-2"]},
          %{
            class: :agent_quality,
            subcategory: :review_gate_rejected,
            count: 1,
            run_ids: ["aq-1"]
          }
        ],
        misclassification: %{corroborated: 0, reclassified: 0, rate: nil, citations: []},
        finding_categories: [],
        difficulty_misestimates: [],
        cells: [],
        suggestions: [],
        notes: []
      }

      md = Report.to_markdown(report)
      # Unclassified runs must be visible with their IDs
      assert md =~ "unclassified"
      assert md =~ "unk-1"
      assert md =~ "unk-2"
    end
  end

  describe "n=1 decline discipline (the bd-7rspia validation)" do
    test "a single-incident finding renders as a per-task override, not a fleet change" do
      report = %Report{
        window: %{label: "last 7d"},
        totals: %{runs: 1, main_runs: 1, failed: 1, completed: 0, tasks: 1, dispatches: 1},
        segmentation: [],
        misclassification: %{corroborated: 0, reclassified: 0, rate: nil, citations: []},
        finding_categories: [
          %{
            category: "plausible code, green tests, inert at runtime",
            incidents: 1,
            tasks: ["bd-7rspia"],
            run_ids: ["5fe011e1"],
            example: "green tests, inert path"
          }
        ],
        difficulty_misestimates: [
          %{
            task_id: "bd-7rspia",
            cell: {1, "arbiter"},
            dispatched_difficulty: 1,
            rounds: 2,
            cost_usd: 10.62,
            note: "misestimate",
            recommendation: %{
              destination: :per_task_override,
              action: "difficulty override + tracked hypothesis",
              target_metric: "round-1 approval",
              baseline: "0%"
            }
          }
        ],
        cells: [],
        suggestions: [
          %{
            title: "plausible code, green tests, inert at runtime",
            target_metric: "round-1 approval rate",
            baseline: "0% (n=1)",
            destination: :per_task_override,
            evidence: %{incidents: 1, tasks: 1},
            verdict: :per_task_override,
            rationale: "n=1 — below the >=3 incidents / >=2 tasks bar; decline fleet-wide change"
          }
        ],
        notes: []
      }

      md = Report.to_markdown(report)
      assert md =~ "per-task" or md =~ "per task"
      assert md =~ "n=1" or md =~ "n = 1"
      # Must explicitly decline a fleet-wide change on this evidence.
      assert md =~ "decline" or (md =~ "not" and md =~ "fleet")
    end
  end
end
