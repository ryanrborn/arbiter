defmodule Arbiter.Workers.StepBackfillTest do
  # bd-apwfmy Phase 2. Live capture only sees runs that happen after it
  # ships; every run already in the corpus has its tool calls sitting in an
  # on-disk session JSONL. This is the retroactive path — and it has to be
  # safely re-runnable, because "run the backfill again" is what anyone does
  # when they are not sure it finished.
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.{Run, RunStep, StepBackfill}
  require Ash.Query

  @lines [
    ~s({"type":"assistant","timestamp":"2026-07-01T20:50:00.000Z","message":{"id":"m-1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"mix test"}}]}}),
    ~s({"type":"user","timestamp":"2026-07-01T20:50:02.500Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":false,"content":"1 test, 0 failures"}]}}),
    ~s({"type":"assistant","timestamp":"2026-07-01T20:50:03.000Z","message":{"id":"m-2","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/x.ex"}}]}}),
    ~s({"type":"user","timestamp":"2026-07-01T20:50:03.250Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":"File does not exist"}]}})
  ]

  # Write a session JSONL where `ClaudeSessionFile.locate/2` will find it:
  # <config_dir>/projects/<any-slug>/<session_id>.jsonl
  defp session_file!(session_id, lines) do
    config_dir = Path.join(System.tmp_dir!(), "cfg-#{System.unique_integer([:positive])}")
    dir = Path.join([config_dir, "projects", "-home-ryan-dev-arbiter"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, session_id <> ".jsonl"), Enum.join(lines, "\n") <> "\n")
    on_exit(fn -> File.rm_rf(config_dir) end)
    config_dir
  end

  defp run!(attrs \\ %{}) do
    session_id = "sess-#{System.unique_integer([:positive])}"
    config_dir = Map.get_lazy(attrs, :config_dir, fn -> session_file!(session_id, @lines) end)

    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: "bd-bf-#{System.unique_integer([:positive])}",
            repo: "arbiter",
            status: :completed,
            started_at: ~U[2026-07-01 20:49:00.000000Z],
            session_id: session_id,
            config_dir: config_dir
          },
          Map.drop(attrs, [:config_dir])
        )
      )

    run
  end

  defp steps_for(run) do
    RunStep
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!()
  end

  describe "backfill_run/2" do
    test "reconstructs typed steps from the session file, tagged as backfilled" do
      run = run!()

      assert {:ok, report} = StepBackfill.backfill_run(run, apply?: true)
      assert report.status == :ok
      assert report.inserted == 2
      assert report.existing == 0

      assert [bash, read] = steps_for(run)

      assert bash.tool_use_id == "toolu_1"
      assert bash.name == "Bash"
      assert bash.is_error == false
      assert bash.duration_ms == 2500
      assert bash.source == "backfill"
      assert bash.run_id == run.id
      assert bash.task_id == run.task_id
      assert bash.input_summary == "mix test"
      assert is_binary(bash.input_digest)
      assert bash.output_summary =~ "1 test, 0 failures"

      assert read.name == "Read"
      assert read.is_error == true
      assert read.input_summary == "/tmp/x.ex"
    end

    test "is idempotent — a second pass inserts nothing" do
      run = run!()

      assert {:ok, %{inserted: 2}} = StepBackfill.backfill_run(run, apply?: true)
      assert {:ok, second} = StepBackfill.backfill_run(run, apply?: true)

      assert second.inserted == 0
      assert second.existing == 2
      assert length(steps_for(run)) == 2
    end

    test "never duplicates a call the live emit path already recorded" do
      run = run!()

      {:ok, _live} =
        Ash.create(RunStep, %{
          run_id: run.id,
          task_id: run.task_id,
          tool_use_id: "toolu_1",
          name: "Bash",
          is_error: false,
          occurred_at: DateTime.utc_now(),
          source: "live"
        })

      assert {:ok, report} = StepBackfill.backfill_run(run, apply?: true)
      assert report.inserted == 1
      assert report.existing == 1

      assert ["toolu_1", "toolu_2"] ==
               run |> steps_for() |> Enum.map(& &1.tool_use_id) |> Enum.sort()
    end

    test "dry run is the default: it reports the count and writes nothing" do
      run = run!()

      assert {:ok, report} = StepBackfill.backfill_run(run)
      assert report.status == :ok
      assert report.inserted == 2
      assert steps_for(run) == []
    end

    test "a run with no locatable session file is reported, not an error" do
      run = run!(%{config_dir: Path.join(System.tmp_dir!(), "definitely-not-here")})

      assert {:ok, report} = StepBackfill.backfill_run(run, apply?: true)
      assert report.status == :no_session_file
      assert report.inserted == 0
      assert steps_for(run) == []
    end

    test "a run with no session_id is reported as such" do
      run = run!(%{session_id: nil})

      assert {:ok, %{status: :no_session_id, inserted: 0}} =
               StepBackfill.backfill_run(run, apply?: true)
    end

    test "secret values are redacted out of the reconstructed summaries" do
      secret = "super-secret-token-value"

      lines = [
        ~s({"type":"assistant","timestamp":"2026-07-01T20:50:00.000Z","message":{"id":"m-1","content":[{"type":"tool_use","id":"toolu_s","name":"Bash","input":{"command":"echo #{secret}"}}]}}),
        ~s({"type":"user","timestamp":"2026-07-01T20:50:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_s","content":"#{secret}"}]}})
      ]

      session_id = "sess-#{System.unique_integer([:positive])}"
      config_dir = session_file!(session_id, lines)
      run = run!(%{session_id: session_id, config_dir: config_dir})

      assert {:ok, %{inserted: 1}} =
               StepBackfill.backfill_run(run, apply?: true, redact_values: [secret])

      assert [step] = steps_for(run)
      refute step.input_summary =~ secret
      refute step.output_summary =~ secret
      refute step.input_digest =~ secret
      assert step.output_summary =~ "[REDACTED]"
    end

    test "an undated call is not guessed into a run that has a start time" do
      # A `--resume`-shared file can hold an earlier run's turns. With a
      # cutoff to compare against, an undated line is ambiguous, and the
      # token reader's rule applies: under-report rather than misattribute.
      lines = [
        ~s({"type":"assistant","message":{"id":"m-1","content":[{"type":"tool_use","id":"toolu_u","name":"Bash","input":{"command":"ls"}}]}}),
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_u","content":"ok"}]}})
      ]

      session_id = "sess-#{System.unique_integer([:positive])}"
      config_dir = session_file!(session_id, lines)
      run = run!(%{session_id: session_id, config_dir: config_dir})

      assert {:ok, %{status: :ok, inserted: 0}} = StepBackfill.backfill_run(run, apply?: true)
      assert steps_for(run) == []
    end
  end

  describe "backfill + StepStats (the whole point of Phase 2)" do
    test "a backfilled run answers \"which tool fails most\" without touching a transcript" do
      run =
        run!(%{repo: "arbiter", resolved_skills: [%{"name" => "tdd", "skill_version" => "1"}]})

      assert {:ok, %{inserted: 2}} = StepBackfill.backfill_run(run, apply?: true)

      rows = Arbiter.Workers.StepStats.tool_outcomes(repo: "arbiter")

      # Worst-first: Read errored, Bash did not.
      assert [worst | _] = rows
      assert worst.tool == "Read"
      assert worst.errors == 1
      assert worst.error_rate == 1.0
      assert worst.skill_set == "tdd"
      assert worst.repo == "arbiter"

      bash = Enum.find(rows, &(&1.tool == "Bash"))
      assert bash.errors == 0
      assert bash.p50_ms == 2500
    end
  end

  describe "backfill/1" do
    test "sweeps runs in the window and aggregates a report" do
      have = run!()

      missing =
        run!(%{
          config_dir: Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")
        })

      report = StepBackfill.backfill(apply?: true, repo: "arbiter")

      assert report.scanned >= 2
      assert report.inserted >= 2
      assert report.no_session_file >= 1

      assert length(steps_for(have)) == 2
      assert steps_for(missing) == []
    end

    test "filters by repo and honours :limit" do
      _arb = run!()
      _other = run!(%{repo: "vs"})

      assert %{scanned: 0} = StepBackfill.backfill(repo: "no-such-repo")
      assert %{scanned: 1} = StepBackfill.backfill(repo: "arbiter", limit: 1)
    end
  end
end
