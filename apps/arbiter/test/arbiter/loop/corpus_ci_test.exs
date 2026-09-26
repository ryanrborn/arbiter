defmodule Arbiter.Loop.CorpusCiTest do
  # bd-cuu8n3: `Corpus.fetch/1`'s `meta.ci` — the PR-bearing task cohort and
  # each in-window fix_pass with the evidence `FixPassClassifier` needs.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Corpus
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.{OutputLog, PromptLog}
  alias Arbiter.Workers.{Run, RunStep}
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "corpus-ci-test-#{System.unique_integer([:positive])}")
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:arbiter, :output_log_root, prev)
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "corpus-ci-ws", prefix: "cc"})
    %{ws: ws}
  end

  defp issue(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "t", difficulty: attrs[:difficulty], workspace_id: ws.id})

    case attrs[:pr_ref] do
      nil -> issue
      ref -> Ash.update!(issue, %{pr_ref: ref})
    end
  end

  defp run(attrs) do
    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{repo: "arbiter", status: :completed, started_at: DateTime.utc_now()},
          attrs
        )
      )

    run
  end

  defp window do
    [
      since: DateTime.add(DateTime.utc_now(), -3600, :second),
      until: DateTime.add(DateTime.utc_now(), 3600, :second),
      record_cost?: false
    ]
  end

  test "carries the PR-bearing cohort, attributed to the task's main run", %{ws: ws} do
    red = issue(ws, difficulty: 3, pr_ref: "#1")
    green = issue(ws, difficulty: 2, pr_ref: "#2")
    no_pr = issue(ws, difficulty: 2)

    for {i, model} <- [{red, "claude-opus-5-5"}, {green, "claude-sonnet-5"}, {no_pr, "m"}] do
      run(%{
        task_id: i.id,
        worker_type: :main,
        model: model,
        provider: "claude",
        workspace_id: ws.id
      })
    end

    run(%{task_id: red.id, worker_type: :fix_pass, model: "claude-sonnet-5", provider: "claude"})

    assert {:ok, _rows, %{ci: ci}} = Corpus.fetch(window())

    by_id = Map.new(ci.tasks, &{&1.task_id, &1})

    assert %{
             pr?: true,
             difficulty: 3,
             model: "claude-opus-5-5",
             provider: "claude",
             repo: "arbiter"
           } =
             by_id[red.id]

    assert %{pr?: true, difficulty: 2} = by_id[green.id]
    assert %{pr?: false} = by_id[no_pr.id]
    assert [%{task_id: task_id}] = ci.fix_passes
    assert task_id == red.id
  end

  test "each fix_pass carries its briefed checks, step signals and final summary", %{ws: ws} do
    i = issue(ws, difficulty: 2, pr_ref: "#3")
    run(%{task_id: i.id, worker_type: :main, model: "m", provider: "claude"})
    fp = run(%{task_id: i.id, worker_type: :fix_pass, model: "m", provider: "claude"})

    :ok =
      PromptLog.write(
        fp.id,
        FixPassDispatcher.prompt_for(%{
          task: i,
          branch: "b",
          target_branch: "main",
          checks: [%{name: "mix precommit (compile, deps, format)", summary: "", url: nil}]
        })
      )

    for {name, input, output} <- [
          {"Edit", "lib/a.ex", "ok"},
          {"Bash", "git commit -am 'format' && git push", "pushed"},
          {"Bash", "gh pr checks 3", "mix precommit\tpass"}
        ] do
      Ash.create!(RunStep, %{
        run_id: fp.id,
        task_id: i.id,
        tool_use_id: "tu-#{System.unique_integer([:positive])}",
        name: name,
        input_summary: input,
        output_summary: output,
        is_error: false,
        occurred_at: DateTime.utc_now()
      })
    end

    {:ok, h} = OutputLog.open(fp.id)

    Enum.each(
      [
        "⏵ Bash(gh pr checks 3)",
        "⏴ tool result",
        "mix precommit\tpass",
        "Ran mix format on one file; CI is green.",
        "arb done"
      ],
      &OutputLog.append(h, &1)
    )

    OutputLog.close(h)

    assert {:ok, _rows, %{ci: %{fix_passes: [fix_pass]}}} = Corpus.fetch(window())

    assert fix_pass.run_id == fp.id
    assert fix_pass.repo == "arbiter"

    assert %{
             checks: [%{name: "mix precommit (compile, deps, format)"}],
             code_changed?: true,
             rerun?: false,
             marked_external?: false,
             summary: "Ran mix format on one file; CI is green."
           } = fix_pass.evidence
  end

  test "the CLI's captured result text outranks the transcript tail", %{ws: ws} do
    i = issue(ws, difficulty: 2, pr_ref: "#4")
    fp = run(%{task_id: i.id, worker_type: :fix_pass, model: "m"})
    Ash.update!(fp, %{result_message: "Re-ran the flaky job; green."})

    assert {:ok, _rows, %{ci: %{fix_passes: [fix_pass]}}} = Corpus.fetch(window())
    assert fix_pass.evidence.summary == "Re-ran the flaky job; green."
    # No step rows at all: the diff is unknown, not empty.
    assert fix_pass.evidence.code_changed? == nil
  end

  test "a fix_pass outside the window is not in the section", %{ws: ws} do
    i = issue(ws, difficulty: 2, pr_ref: "#5")

    run(%{
      task_id: i.id,
      worker_type: :fix_pass,
      started_at: DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
    })

    assert {:ok, _rows, %{ci: %{fix_passes: []}}} = Corpus.fetch(window())
  end

  describe "flake_events (bd-6vullc)" do
    test "carries a flake event recorded in the window", %{ws: ws} do
      i = issue(ws, difficulty: 2, pr_ref: "#6")

      {:ok, event} =
        Arbiter.Loop.Flakes.record(%{
          task_id: i.id,
          repo: "arbiter",
          ci_job: "mix test",
          signature: "DataCase teardown timeout",
          test_file: "test/coverage_test.exs",
          test_line: 150
        })

      assert {:ok, _rows, %{ci: %{flake_events: [flake]}}} = Corpus.fetch(window())

      assert flake.task_id == i.id
      assert flake.run_id == event.run_id
      assert flake.repo == "arbiter"
      assert flake.ci_job == "mix test"
      assert flake.test_file == "test/coverage_test.exs"
      assert flake.test_line == 150
      assert flake.signature == "DataCase teardown timeout"
    end

    test "a flake event outside the window is not carried", %{ws: ws} do
      i = issue(ws, difficulty: 2, pr_ref: "#7")

      {:ok, _event} =
        Arbiter.Loop.Flakes.record(%{
          task_id: i.id,
          repo: "arbiter",
          ci_job: "mix test",
          signature: "old flake"
        })

      old_since = DateTime.add(DateTime.utc_now(), -365 * 24 * 3600, :second)
      old_until = DateTime.add(DateTime.utc_now(), -364 * 24 * 3600, :second)

      assert {:ok, _rows, %{ci: %{flake_events: []}}} =
               Corpus.fetch(since: old_since, until: old_until, record_cost?: false)
    end
  end
end
