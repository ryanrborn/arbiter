defmodule Arbiter.Loop.PassIntegrationTest do
  # End-to-end: seed real runs/usage/rounds + transcripts, run the pass, assert
  # it emits a report, records exactly one own-cost usage row, and writes
  # nothing else. async: false — we swap the :output_log_root app env and the
  # pass reads via raw SQL on the sandbox connection.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Analysis
  alias Arbiter.Workers.Run
  alias Arbiter.Usage.Event
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.OutputLog
  require Ash.Query

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "loop-pass-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "loop-test-ws", prefix: "loop"})
    %{ws: ws}
  end

  defp issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "seed", difficulty: 2, workspace_id: ws.id}, attrs))

    issue
  end

  defp run!(attrs) do
    base = %{
      repo: "arbiter",
      worker_type: :main,
      status: :completed,
      model: "claude-sonnet-5",
      started_at: DateTime.utc_now()
    }

    {:ok, run} = Ash.create(Run, Map.merge(base, attrs))
    run
  end

  defp usage!(run, cost) do
    {:ok, _} =
      Ash.create(Event, %{
        task_id: run.task_id,
        step: :work,
        worker_run_id: run.id,
        cost_usd: cost,
        occurred_at: DateTime.utc_now()
      })
  end

  defp transcript!(run_id, lines) do
    {:ok, h} = OutputLog.open(run_id)
    Enum.each(lines, &OutputLog.append(h, &1))
    OutputLog.close(h)
  end

  defp count(resource), do: resource |> Ash.read!() |> length()

  test "the pass runs over the window, emits a disciplined report, and writes only its own-cost row",
       %{ws: ws} do
    # --- bd-7rspia analogue: D1, economy Haiku rejected (round 2), Sonnet re-run approved.
    inert_issue = issue!(ws, %{difficulty: 1, title: "inert-at-runtime task"})

    haiku =
      run!(%{
        task_id: inert_issue.id,
        status: :failed,
        model: "claude-haiku-4-5",
        failure_reason: ":review_gate_rejected"
      })

    sonnet = run!(%{task_id: inert_issue.id, status: :completed, model: "claude-sonnet-5"})

    usage!(haiku, 4.44)
    usage!(sonnet, 6.18)

    {:ok, _} =
      Ash.create(Round, %{
        task_id: inert_issue.id,
        run_id: haiku.id,
        round: 2,
        role: :review,
        verdict: :request_changes,
        converged: false,
        findings: "Tests are green but the new code path is never executed at runtime — inert."
      })

    # --- c88c77b0 analogue: rate-limited LABEL, but the transcript is context exhaustion.
    c88 =
      run!(%{
        task_id: "bd-dyfaq3",
        status: :failed,
        model: "claude-opus-4-8",
        failure_reason: "agent was rate-limited / the API was overloaded"
      })

    transcript!(c88.id, [
      "reading apps/arbiter/lib/arbiter/quota/anthropic_quota.ex",
      "Autocompact is thrashing: the context refilled to the limit within 3 turns of the previous compact, 3 times in a row.",
      "⚙ claude session error · 523.8s · $4.6105"
    ])

    usage!(c88, 4.61)

    issues_before = count(Issue)
    runs_before = count(Run)
    rounds_before = count(Round)
    events_before = count(Event)

    assert {:ok, %{report: report, markdown: md, usage_event_id: uid}} =
             Analysis.analyze(
               label: "integration window",
               since: DateTime.add(DateTime.utc_now(), -24 * 3600, :second),
               until: DateTime.add(DateTime.utc_now(), 120, :second)
             )

    # --- the report exists and carries the disciplined content
    assert is_binary(md) and byte_size(md) > 0
    assert md =~ inert_issue.id
    assert md =~ c88.id
    assert md =~ "context_exhaustion"
    assert md =~ "per-task override"
    assert md =~ "decline"

    # c88 is classified agent-quality/context_exhaustion despite the label, and
    # is surfaced in the misclassification finding.
    assert report.misclassification.reclassified >= 1
    assert Enum.any?(report.misclassification.citations, &(&1.run_id == c88.id))

    seg = Enum.find(report.segmentation, &(c88.id in &1.run_ids))
    assert seg.class == :agent_quality
    assert seg.subcategory == :context_exhaustion

    # bd-7rspia analogue: difficulty misestimate, cost summed across attempts,
    # declined for a fleet-wide change (n=1).
    mis = Enum.find(report.difficulty_misestimates, &(&1.task_id == inert_issue.id))
    assert mis
    assert_in_delta mis.cost_usd, 10.62, 0.001

    inert = Enum.find(report.suggestions, &(&1.title =~ "inert at runtime"))
    assert inert.verdict == :per_task_override

    # --- ZERO WRITES except the single own-cost usage row
    assert count(Issue) == issues_before
    assert count(Run) == runs_before
    assert count(Round) == rounds_before
    assert count(Event) == events_before + 1

    assert uid
    {:ok, ev} = Ash.get(Event, uid)
    assert ev.model == "loop-analysis-pass"
    assert ev.step == :other
    assert ev.provider == "arbiter"
  end
end
