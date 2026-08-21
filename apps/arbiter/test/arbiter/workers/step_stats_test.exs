defmodule Arbiter.Workers.StepStatsTest do
  # bd-apwfmy (Definition of done, item 3): "which tool fails most, on which
  # repo, under which skill set" must be ONE SQL query over the typed step
  # rows — not a transcript scan, and not a migration per new question.
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.{Run, RunStep, StepStats}

  defp run!(attrs) do
    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: "bd-stats-#{System.unique_integer([:positive])}",
            repo: "arbiter",
            status: :completed,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    run
  end

  defp step!(run, attrs) do
    {:ok, step} =
      Ash.create(
        RunStep,
        Map.merge(
          %{
            run_id: run.id,
            task_id: run.task_id,
            tool_use_id: "tu-#{System.unique_integer([:positive])}",
            is_error: false,
            occurred_at: DateTime.utc_now()
          },
          attrs
        )
      )

    step
  end

  describe "tool_outcomes/1" do
    test "ranks tools by error count, per repo and per resolved skill set" do
      skills = [%{"name" => "tdd", "skill_version" => "1"}]
      arb = run!(%{repo: "arbiter", resolved_skills: skills})
      other = run!(%{repo: "vs", resolved_skills: skills})

      # Bash: 3 calls in arbiter, 2 of them errors.
      step!(arb, %{name: "Bash", is_error: true, duration_ms: 100})
      step!(arb, %{name: "Bash", is_error: true, duration_ms: 300})
      step!(arb, %{name: "Bash", is_error: false, duration_ms: 200})
      # Read: 1 clean call in arbiter.
      step!(arb, %{name: "Read", is_error: false, duration_ms: 10})
      # Bash in a different repo is its own cell.
      step!(other, %{name: "Bash", is_error: true, duration_ms: 50})

      rows = StepStats.tool_outcomes()

      bash_arb = Enum.find(rows, &(&1.tool == "Bash" and &1.repo == "arbiter"))
      assert bash_arb.calls == 3
      assert bash_arb.errors == 2
      assert_in_delta bash_arb.error_rate, 2 / 3, 0.001
      assert bash_arb.skill_set == "tdd"

      read_arb = Enum.find(rows, &(&1.tool == "Read"))
      assert read_arb.calls == 1
      assert read_arb.errors == 0
      assert read_arb.error_rate == 0.0

      bash_vs = Enum.find(rows, &(&1.tool == "Bash" and &1.repo == "vs"))
      assert bash_vs.calls == 1
      assert bash_vs.errors == 1

      # Worst-first ordering is what makes this directly reportable.
      assert hd(rows).tool == "Bash"
      assert hd(rows).repo == "arbiter"
    end

    test "reports p50/p95 duration per cell, ignoring rows with no timing" do
      run = run!(%{repo: "arbiter"})

      Enum.each([10, 20, 30, 40, 100], fn ms ->
        step!(run, %{name: "Bash", duration_ms: ms})
      end)

      # A backfilled row with no timing must not be counted as a 0ms call.
      step!(run, %{name: "Bash", duration_ms: nil})

      [cell] = StepStats.tool_outcomes()
      assert cell.calls == 6
      assert cell.timed_calls == 5
      assert cell.p50_ms == 30
      assert cell.p95_ms == 100
    end

    test "a run with no resolved_skills reports an empty skill set, not a crash" do
      run = run!(%{repo: "arbiter"})
      step!(run, %{name: "Grep", is_error: true})

      [cell] = StepStats.tool_outcomes()
      assert cell.skill_set == ""
      assert cell.errors == 1
      assert cell.p50_ms == nil
      assert cell.p95_ms == nil
    end

    test "windows by :since / :until and filters by :repo" do
      old = run!(%{repo: "arbiter"})
      recent = run!(%{repo: "arbiter"})
      elsewhere = run!(%{repo: "vs"})

      long_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
      step!(old, %{name: "Bash", occurred_at: long_ago})
      step!(recent, %{name: "Bash"})
      step!(elsewhere, %{name: "Bash"})

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert [cell] = StepStats.tool_outcomes(since: since, repo: "arbiter")
      assert cell.calls == 1

      assert [_ | _] = StepStats.tool_outcomes(repo: "arbiter")
      assert StepStats.tool_outcomes(repo: "nope") == []
    end

    test "steps whose run row is gone are dropped, not attributed to a nil repo" do
      orphan = run!(%{repo: "arbiter"})
      step!(orphan, %{name: "Bash", run_id: Ash.UUID.generate()})

      assert StepStats.tool_outcomes() == []
    end
  end
end
