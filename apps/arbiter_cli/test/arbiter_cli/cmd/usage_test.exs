defmodule ArbiterCli.Cmd.UsageTest do
  @moduledoc """
  bd-3j4ch4 AC4: `arb usage --calibration` renders the mis-rating report.
  """

  use ArbiterCli.CliCase, async: false

  @report %{
    "window_days" => 60,
    "re_dispatched_flagged" => 1,
    "tiers" => [
      %{
        "difficulty" => 1,
        "n" => 10,
        "re_dispatched" => 0,
        "n_scored" => 10,
        "p25" => 3.0,
        "median" => 5.0,
        "p75" => 8.0,
        "p90" => 9.0,
        "under_rated" => 0,
        "over_rated" => 0,
        "under_rate" => 0.0,
        "over_rate" => 0.0
      },
      %{
        "difficulty" => 2,
        "n" => 13,
        "re_dispatched" => 1,
        "n_scored" => 12,
        "p25" => 13.0,
        "median" => 16.0,
        "p75" => 19.0,
        "p90" => 25.0,
        "under_rated" => 1,
        "over_rated" => 1,
        "under_rate" => 1 / 12,
        "over_rate" => 1 / 12
      }
    ],
    "flagged" => [
      %{
        "task_id" => "bd-under1",
        "title" => "looks like a D3",
        "difficulty" => 2,
        "issue_type" => "feature",
        "actual_cost_usd" => 25.0,
        "direction" => "under_rated",
        "suggested_difficulty" => 3,
        "re_dispatched" => false
      },
      %{
        "task_id" => "bd-reslung",
        "title" => "re-slung, not mis-rated",
        "difficulty" => 2,
        "issue_type" => "feature",
        "actual_cost_usd" => 26.0,
        "direction" => "under_rated",
        "suggested_difficulty" => 3,
        "re_dispatched" => true
      },
      %{
        "task_id" => "bd-over1",
        "title" => "looks like a D1",
        "difficulty" => 2,
        "issue_type" => "chore",
        "actual_cost_usd" => 5.0,
        "direction" => "over_rated",
        "suggested_difficulty" => 1,
        "re_dispatched" => false
      }
    ]
  }

  describe "arb usage --calibration" do
    test "prints per-tier rates and both mis-rating directions" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert code == 0
      assert out =~ "Cost calibration"
      assert out =~ "60-day window"

      # Per-tier rates.
      assert out =~ "D2"
      assert out =~ "$13.00"
      assert out =~ "$19.00"
      assert out =~ "8.3%"

      # Both directions are listed, with the suggested tier.
      assert out =~ "under-rated"
      assert out =~ "over-rated"
      assert out =~ "bd-under1"
      assert out =~ "bd-over1"
      assert out =~ "D2 -> D3"
      assert out =~ "D2 -> D1"
    end

    test "footnotes the re-dispatched tasks it kept out of the rates" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert out =~ "bd-reslung"
      assert out =~ "re-dispatched"
      # The marker on the row itself, so the table is readable without the
      # footnote.
      assert out =~ "*"
    end

    test "--json emits the raw report" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, 0} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration", "--json"]) end)

      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["window_days"] == 60
      assert length(decoded["flagged"]) == 3
    end

    test "an empty report says so rather than printing an empty table" do
      stub_get("/api/usage/calibration", %{
        "window_days" => 60,
        "re_dispatched_flagged" => 0,
        "tiers" => [],
        "flagged" => []
      })

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert out =~ "no rated closed tasks"
    end
  end
end
