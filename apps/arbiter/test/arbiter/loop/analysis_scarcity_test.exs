defmodule Arbiter.Loop.AnalysisScarcityTest do
  @moduledoc """
  #1463 (epic #1011 Amendment E): the analyser's objective function is
  denominated in the binding 5h quota window, not in imputed dollars.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Loop.{Analysis, Report, Scarcity}

  defp calibrated(capacity \\ 1_000_000.0) do
    cal = Scarcity.calibrate(capacity * 0.5, %{utilization_5h: 0.5, captured_at: ~U[2026-09-04 09:00:00Z]})
    %{
      unit: :window_share_5h,
      secondary_unit: :cost_usd,
      billing_mode: {:subscription, :inferred},
      calibration: cal
    }
  end

  defp metered do
    %{
      unit: :cost_usd,
      secondary_unit: :window_share_5h,
      billing_mode: {:metered, :default},
      calibration: Scarcity.calibrate(0.0, nil)
    }
  end

  defp meta(scarcity) do
    %{
      label: "test window",
      since: ~U[2026-09-01 00:00:00Z],
      until: ~U[2026-09-04 00:00:00Z],
      workspace_id: "ws-1",
      failed_runs: 0,
      transcript_reads: 0,
      scarcity: scarcity
    }
  end

  defp row(attrs) do
    Map.merge(
      %{
        run_id: "r-#{System.unique_integer([:positive])}",
        task_id: "bd-1",
        repo: "arbiter",
        title: nil,
        worker_type: :main,
        status: :completed,
        model: "claude-sonnet-5",
        model_tier: nil,
        difficulty: 3,
        difficulty_source: :issue,
        failure_reason: nil,
        stop_category: nil,
        cost_usd: 1.0,
        weighted_tokens: 10_000.0,
        window_share_5h: 0.01,
        max_round: 1,
        rejected?: false,
        converged?: true,
        findings: [],
        transcript_read?: false,
        terminal_lines: []
      },
      attrs
    )
  end

  describe "cells" do
    test "each cell reports mean 5h-window share alongside mean cost" do
      rows = [
        row(%{task_id: "bd-a", window_share_5h: 0.02, cost_usd: 2.0}),
        row(%{task_id: "bd-b", window_share_5h: 0.04, cost_usd: 1.0})
      ]

      report = Analysis.build_report(rows, meta: meta(calibrated()))
      [cell] = report.cells

      assert_in_delta cell.mean_window_share_5h, 0.03, 0.0001
      assert_in_delta cell.mean_cost_usd, 1.5, 0.0001
    end

    test "an uncalibrated window leaves mean window share nil, not zero" do
      rows = [row(%{task_id: "bd-a", window_share_5h: nil})]
      report = Analysis.build_report(rows, meta: meta(metered()))
      [cell] = report.cells

      assert cell.mean_window_share_5h == nil
    end
  end

  describe "the objective function the cohort comparison uses" do
    # The whole point of Amendment E: a task that is CHEAPER in dollars than its
    # cell peers but draws MORE of the binding 5h window must still be flagged.
    # Under the old cost-denominated comparison it was invisible.
    defp cheap_but_window_hungry_rows do
      [
        # Subject: 2 review rounds, below-median dollars, above-median draw.
        row(%{task_id: "bd-subject", max_round: 2, cost_usd: 0.10, window_share_5h: 0.30}),
        row(%{task_id: "bd-peer-1", max_round: 1, cost_usd: 5.00, window_share_5h: 0.01}),
        row(%{task_id: "bd-peer-2", max_round: 1, cost_usd: 5.00, window_share_5h: 0.01})
      ]
    end

    test "under subscription billing a cheap but window-hungry rework is flagged" do
      report = Analysis.build_report(cheap_but_window_hungry_rows(), meta: meta(calibrated()))

      assert [mis] = report.difficulty_misestimates
      assert mis.task_id == "bd-subject"
      assert_in_delta mis.window_share_5h, 0.30, 0.0001
    end

    test "under metered billing the same rework is dropped — dollars still bind there" do
      report = Analysis.build_report(cheap_but_window_hungry_rows(), meta: meta(metered()))

      assert report.difficulty_misestimates == []
    end
  end

  describe "pre-registered target metric" do
    test "the difficulty_override proposal registers a quota-denominated metric and baseline" do
      report = Analysis.build_report(cheap_but_window_hungry_rows(), meta: meta(calibrated()))
      [mis] = report.difficulty_misestimates
      rec = mis.recommendation

      assert rec.target_metric =~ "5h-window share to converge"
      assert rec.target_metric =~ "bd-subject"
      # The baseline is pre-registered in the same unit, with the rounds figure
      # retained as the leading indicator.
      assert rec.baseline =~ "of one 5h window"
      assert rec.baseline =~ "round-1 approval"
    end

    test "under metered billing the same proposal stays dollar/rounds denominated" do
      rows = [
        row(%{task_id: "bd-subject", max_round: 2, cost_usd: 9.00, window_share_5h: nil}),
        row(%{task_id: "bd-peer-1", max_round: 1, cost_usd: 1.00, window_share_5h: nil}),
        row(%{task_id: "bd-peer-2", max_round: 1, cost_usd: 1.00, window_share_5h: nil})
      ]

      report = Analysis.build_report(rows, meta: meta(metered()))
      [mis] = report.difficulty_misestimates

      assert mis.recommendation.target_metric =~ "round-1 approval rate"
      refute mis.recommendation.target_metric =~ "5h-window"
    end
  end

  describe "report scarcity disclosure" do
    test "the report carries the unit, how billing mode was determined, and the calibration" do
      report = Analysis.build_report([row(%{})], meta: meta(calibrated()))

      assert report.scarcity.unit == :window_share_5h
      assert report.scarcity.billing_mode == {:subscription, :inferred}
      assert report.scarcity.calibration.status == :calibrated

      md = Report.to_markdown(report)
      assert md =~ "## Unit of scarcity"
      assert md =~ "5-hour utilization window"
      assert md =~ "subscription"
      assert md =~ "inferred"
    end

    test "an uncalibrated window is disclosed rather than rendered as a zero draw" do
      report = Analysis.build_report([row(%{window_share_5h: nil})], meta: meta(metered()))
      md = Report.to_markdown(report)

      assert md =~ "uncalibrated"
      assert md =~ "no_snapshot"
    end

    test "the analyser's own quota draw is stated in the report" do
      report = Analysis.build_report([row(%{})], meta: meta(calibrated()))
      md = Report.to_markdown(report)

      assert md =~ "own draw"
      assert md =~ "deterministic"
    end
  end
end
