defmodule Arbiter.Loop.ScarcityPassIntegrationTest do
  @moduledoc """
  #1463 acceptance, end to end: run the real pass (`Analysis.analyze/1`,
  `propose?: true`) against a seeded window and assert the persisted
  `PendingWrite` pre-registers a quota-denominated target metric and baseline.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{Analysis, PendingWrite}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  # Two peers converging in round 1 on many dollars but few tokens, and a
  # subject reworked over two rounds on few dollars but many tokens. Under the
  # old cost-denominated cohort test the subject is dropped; under the 5h-window
  # objective it is the outlier.
  defp seed! do
    {:ok, ws} = Ash.create(Workspace, %{name: "scarcity-pass-ws", prefix: "scpw"})

    subject = task!(ws, "window-hungry rework", rounds: 2, cost: 0.10, tokens_out: 200_000)
    _peer1 = task!(ws, "cheap peer one", rounds: 1, cost: 9.00, tokens_out: 1_000)
    _peer2 = task!(ws, "cheap peer two", rounds: 1, cost: 9.00, tokens_out: 1_000)

    # Captured after the work it measures: the calibration sums the observed draw
    # over `[window_start, captured_at]`, the interval this reading describes.
    {:ok, _q} =
      Ash.create(AnthropicQuota, %{
        workspace_id: ws.id,
        provider: "claude",
        utilization_5h: 0.5,
        captured_at: DateTime.utc_now()
      })

    %{ws: ws, subject: subject}
  end

  defp task!(ws, title, opts) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, difficulty: 2, workspace_id: ws.id})

    {:ok, run} =
      Ash.create(Run, %{
        task_id: issue.id,
        repo: "arbiter",
        worker_type: :main,
        status: :completed,
        model: "claude-sonnet-5",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Event, %{
        task_id: issue.id,
        workspace_id: ws.id,
        step: :work,
        worker_run_id: run.id,
        cost_usd: Keyword.fetch!(opts, :cost),
        tokens_in: 1_000,
        tokens_out: Keyword.fetch!(opts, :tokens_out),
        occurred_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

    {:ok, _} =
      Ash.create(Round, %{
        task_id: issue.id,
        run_id: run.id,
        round: Keyword.fetch!(opts, :rounds),
        role: :review,
        verdict: :approve,
        converged: true
      })

    issue
  end

  test "the pass proposes a difficulty override pre-registered in 5h-window share" do
    %{ws: ws, subject: subject} = seed!()

    {:ok, envelope} =
      Analysis.analyze(
        since: DateTime.add(DateTime.utc_now(), -3600, :second),
        until: DateTime.add(DateTime.utc_now(), 3600, :second),
        workspace_id: ws.id,
        propose?: true
      )

    report = envelope.report

    # The pass read the installation's billing mode and calibrated the window.
    assert report.scarcity.unit == :window_share_5h
    assert report.scarcity.billing_mode == {:subscription, :inferred}
    assert report.scarcity.calibration.status == :calibrated

    # The cheap-but-window-hungry task is the flagged misestimate.
    assert [mis] = report.difficulty_misestimates
    assert mis.task_id == subject.id
    assert is_float(mis.window_share_5h)

    # And it persisted as a proposal carrying the quota-denominated
    # pre-registration.
    writes = Ash.read!(PendingWrite)
    override = Enum.find(writes, &(&1.kind == :difficulty_override))

    assert override,
           "expected a :difficulty_override proposal, got #{inspect(Enum.map(writes, & &1.kind))}"

    assert override.target_metric =~ "5h-window share to converge"
    assert override.baseline =~ "of one 5h window"
    assert override.baseline =~ "round-1 approval"

    # The one-line summary an operator actually approves on is in the same unit
    # as the pre-registration it summarises — not "$0.10" beside a window-share
    # baseline.
    assert override.gist =~ "of one 5h window"
    refute override.gist =~ "$"

    # Dollars are retained, not deleted: the report still carries mean cost.
    assert [cell] = report.cells
    assert is_float(cell.mean_cost_usd)
    assert is_float(cell.mean_window_share_5h)

    # The operator-facing markdown is the real output surface: it states the
    # unit before any number denominated in it, and reports the subject's draw.
    md = envelope.markdown
    if System.get_env("SHOW_LOOP_REPORT"), do: IO.puts(md)
    assert md =~ "## Unit of scarcity"
    assert md =~ "| billing mode | subscription (inferred) |"
    assert md =~ "| primary unit | `window_share_5h` |"
    assert md =~ "mean 5h share"
    assert md =~ "**5h-window share:**"
    assert md =~ "5h-window share to converge"
    assert md =~ "Analyser's own draw on the quota windows it measures: none"

    # The pass's own draw is recorded as an explicit zero.
    {:ok, own} = Ash.get(Event, envelope.usage_event_id)
    assert own.tokens_in == 0
    assert own.tokens_out == 0
    assert own.raw["quota_window_draw"] == "none"
  end
end
