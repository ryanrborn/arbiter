defmodule Arbiter.Loop.ProposalsTest do
  # The report → candidate mapping (pure) and the `propose?:` opt-in on the pass
  # (which must leave the default path byte-identical to Stage 1).
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{Analysis, PendingWrite, Proposals, Report}
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  defp report(attrs), do: struct(Report, attrs)

  defp finding_category(attrs \\ %{}) do
    Map.merge(
      %{
        category: "plausible code, green tests, inert at runtime",
        count: 3,
        run_ids: ["run-1", "run-2", "run-3"],
        tasks: ["bd-aaa", "bd-bbb"],
        example: "the new code path is never executed"
      },
      attrs
    )
  end

  describe "candidates/2 (pure)" do
    test "every finding category becomes a fleet-scoped skill_patch, below-bar ones included" do
      r =
        report(%{
          finding_categories: [
            finding_category(),
            finding_category(%{category: "thin test", count: 1, run_ids: ["r9"], tasks: ["bd-z"]})
          ],
          suggestions: [
            %{
              title: "plausible code, green tests, inert at runtime",
              target_metric: "rework rate",
              baseline: "42.0%",
              destination: :skill,
              verdict: :fleet_wide
            }
          ]
        })

      candidates = Proposals.candidates(r)

      assert length(candidates) == 2
      assert Enum.all?(candidates, &(&1.kind == :skill_patch and &1.scope == :fleet))

      inert = Enum.find(candidates, &(&1.category =~ "inert at runtime"))
      assert inert.incident_refs == ["run-1", "run-2", "run-3"]
      assert inert.task_refs == ["bd-aaa", "bd-bbb"]
      # The metric and its baseline are pre-registered at propose time, for the
      # later re-grading pass to measure against.
      assert inert.target_metric == "rework rate"
      assert inert.baseline == "42.0%"

      # Stage 3 gap: no target skill is named, so nothing here claims to know
      # which skill the patch belongs in.
      refute Map.has_key?(inert.payload, "skill")

      thin = Enum.find(candidates, &(&1.category == "thin test"))
      assert thin, "a below-bar category is still a candidate — that is the point of Stage 2"
      assert thin.incident_refs == ["r9"]
    end

    test "a rework misestimate becomes a task-scoped difficulty_override with a diff" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-7rspia",
              dispatched_difficulty: 1,
              rounds: 2,
              cost_usd: 10.62,
              reason: :rework,
              cell: {1, "arbiter"},
              recommendation: %{target_metric: "rework rate", baseline: "50.0%"}
            }
          ]
        })

      assert [candidate] = Proposals.candidates(r)

      assert candidate.kind == :difficulty_override
      assert candidate.scope == :task
      assert candidate.target == "bd-7rspia"
      assert candidate.difficulty == 1
      assert candidate.repo == "arbiter"
      assert candidate.payload["task_id"] == "bd-7rspia"
      assert candidate.payload["difficulty"] == 2
      assert candidate.gist =~ "D1 → D2"
      assert candidate.diff =~ "-difficulty: 1"
      assert candidate.diff =~ "+difficulty: 2"
    end

    test "a quality_failure misestimate is deliberately not a candidate" do
      r =
        report(%{
          difficulty_misestimates: [
            %{
              task_id: "bd-cost",
              dispatched_difficulty: 3,
              rounds: 1,
              cost_usd: 22.0,
              reason: :quality_failure,
              cell: {3, "arbiter"}
            }
          ]
        })

      assert Proposals.candidates(r) == []
    end

    test "candidates carry the workspace and origin they were built with" do
      r = report(%{finding_categories: [finding_category()]})

      assert [c] = Proposals.candidates(r, workspace_id: "ws-1", origin: "loop.manual")
      assert c.workspace_id == "ws-1"
      assert c.origin == "loop.manual"
    end

    test "candidates/2 writes nothing" do
      r = report(%{finding_categories: [finding_category()]})

      _ = Proposals.candidates(r)

      assert Ash.read!(PendingWrite) == []
    end
  end

  describe "the propose? opt-in on the pass" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "propose-ws", prefix: "prop"})

      {:ok, issue} =
        Ash.create(Issue, %{title: "inert task", difficulty: 1, workspace_id: ws.id})

      {:ok, run} =
        Ash.create(Run, %{
          task_id: issue.id,
          repo: "arbiter",
          worker_type: :main,
          status: :failed,
          model: "claude-haiku-4-5",
          failure_reason: ":review_gate_rejected",
          started_at: DateTime.utc_now()
        })

      {:ok, _} =
        Ash.create(Event, %{
          task_id: issue.id,
          step: :work,
          worker_run_id: run.id,
          cost_usd: 4.44,
          occurred_at: DateTime.utc_now()
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 2,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "Tests are green but the new code path is never executed at runtime — inert."
        })

      %{ws: ws, issue: issue}
    end

    defp analyze!(opts) do
      base = [
        label: "propose window",
        since: DateTime.add(DateTime.utc_now(), -24 * 3600, :second),
        until: DateTime.add(DateTime.utc_now(), 120, :second)
      ]

      {:ok, envelope} = Analysis.analyze(Keyword.merge(base, opts))
      envelope
    end

    test "without propose? the envelope has no :proposals key and the queue stays empty" do
      envelope = analyze!([])

      refute Map.has_key?(envelope, :proposals)
      assert Ash.read!(PendingWrite) == []
    end

    test "with propose? rows are inserted and nothing else is written", %{issue: issue} do
      issues_before = Issue |> Ash.read!() |> length()
      runs_before = Run |> Ash.read!() |> length()
      rounds_before = Round |> Ash.read!() |> length()
      events_before = Event |> Ash.read!() |> length()

      envelope = analyze!(propose?: true)

      assert is_list(envelope.proposals)
      assert envelope.proposals != []

      rows = Ash.read!(PendingWrite)
      assert length(rows) == length(envelope.proposals)

      # The queue is the only thing that grew, bar the pass's own cost row.
      assert Issue |> Ash.read!() |> length() == issues_before
      assert Run |> Ash.read!() |> length() == runs_before
      assert Round |> Ash.read!() |> length() == rounds_before
      assert Event |> Ash.read!() |> length() == events_before + 1

      # The task-scoped difficulty bump bypasses the bar; the fleet-wide finding
      # (1 incident) does not.
      override = Enum.find(rows, &(&1.kind == :difficulty_override))
      assert override.scope == :task
      assert override.state == :proposed
      assert override.target == issue.id

      patch = Enum.find(rows, &(&1.kind == :skill_patch))
      assert patch.scope == :fleet
      assert patch.state == :hypothesis
      refute Loop.applicable?(patch)
    end

    test "two consecutive propose runs over the same window produce no duplicate rows" do
      first = analyze!(propose?: true)
      after_first = Ash.read!(PendingWrite)

      second = analyze!(propose?: true)
      after_second = Ash.read!(PendingWrite)

      assert length(after_second) == length(after_first)

      assert Enum.map(first.proposals, & &1.id) |> Enum.sort() ==
               Enum.map(second.proposals, & &1.id) |> Enum.sort()

      # Reinforcement unions the refs, so re-running the same window does not
      # inflate the evidence either.
      by_id = Map.new(after_first, &{&1.id, &1})

      for row <- after_second do
        before = Map.fetch!(by_id, row.id)
        assert row.evidence_count == before.evidence_count
        assert row.distinct_tasks == before.distinct_tasks
      end
    end
  end
end
