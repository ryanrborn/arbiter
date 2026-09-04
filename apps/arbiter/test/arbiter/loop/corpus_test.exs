defmodule Arbiter.Loop.CorpusTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Corpus
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run

  describe "fetch/1 — infra fingerprints outside the bounded tail" do
    setup do
      prev = Application.get_env(:arbiter, :output_log_root)
      root = Path.join(System.tmp_dir!(), "corpus-test-#{System.unique_integer([:positive])}")
      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev do
          Application.put_env(:arbiter, :output_log_root, prev)
        else
          Application.delete_env(:arbiter, :output_log_root)
        end
      end)

      :ok
    end

    test "a proxy_5xx fingerprint 200+ lines back from the end still reaches terminal_lines" do
      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-test-fingerprint",
          repo: "arbiter",
          status: :failed,
          failure_reason: "claude session error",
          started_at: DateTime.utc_now()
        })

      {:ok, handle} = OutputLog.open(run.id)
      OutputLog.append(handle, "** (Phoenix.Ecto.PendingMigrationError) migrations pending")
      Enum.each(1..200, fn i -> OutputLog.append(handle, "line #{i}") end)
      OutputLog.close(handle)

      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, [row], _meta} = Corpus.fetch(since: since, until: until)

      assert Enum.any?(row.terminal_lines, &String.contains?(&1, "PendingMigrationError"))
    end

    test "context-exhaustion detection (tail-only signal) is unaffected by the fingerprint scan" do
      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-test-context-exhaustion",
          repo: "arbiter",
          status: :failed,
          failure_reason: "agent was rate-limited / the API was overloaded",
          started_at: DateTime.utc_now()
        })

      {:ok, handle} = OutputLog.open(run.id)
      Enum.each(1..200, fn i -> OutputLog.append(handle, "line #{i}") end)
      OutputLog.append(handle, "Autocompact is thrashing — context window exhausted")
      OutputLog.close(handle)

      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, [row], _meta} = Corpus.fetch(since: since, until: until)

      # No infra fingerprint present — the autocompact line must still be
      # visible (it's within the bounded tail), and no fingerprint lines
      # were spuriously added.
      refute Enum.any?(row.terminal_lines, &String.contains?(&1, "PendingMigrationError"))
      refute Enum.any?(row.terminal_lines, &String.contains?(&1, "DBConnection"))

      result =
        Arbiter.Loop.FailureClassifier.classify(row.failure_reason, row.terminal_lines)

      assert result.class == :agent_quality
      assert result.subcategory == :context_exhaustion
    end
  end

  # bd-apwfmy (Definition of done, item 2): a failed run whose typed
  # `stop_category` already decides the classification must not have its
  # transcript read at all. The bounded-read discipline stays for everything
  # else, and the meta reports how much of the window still needed it.
  describe "fetch/1 — structured stop_category replaces the transcript read" do
    setup do
      prev = Application.get_env(:arbiter, :output_log_root)
      root = Path.join(System.tmp_dir!(), "corpus-steps-#{System.unique_integer([:positive])}")
      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev do
          Application.put_env(:arbiter, :output_log_root, prev)
        else
          Application.delete_env(:arbiter, :output_log_root)
        end
      end)

      :ok
    end

    defp failed_run(task_id, attrs) do
      {:ok, run} =
        Ash.create(
          Run,
          Map.merge(
            %{
              task_id: task_id,
              repo: "arbiter",
              status: :failed,
              started_at: DateTime.utc_now()
            },
            attrs
          )
        )

      run
    end

    defp write_log(run_id, lines) do
      {:ok, handle} = OutputLog.open(run_id)
      Enum.each(lines, &OutputLog.append(handle, &1))
      OutputLog.close(handle)
    end

    defp window do
      [
        since: DateTime.add(DateTime.utc_now(), -3600, :second),
        until: DateTime.add(DateTime.utc_now(), 3600, :second)
      ]
    end

    test "a conclusive stop_category skips the transcript read entirely" do
      run =
        failed_run("bd-corpus-typed", %{
          failure_reason: "agent was rate-limited / the API was overloaded",
          stop_category: "context_thrash"
        })

      write_log(run.id, ["should not be read", "Autocompact is thrashing"])

      assert {:ok, [row], meta} = Corpus.fetch(window())

      assert row.stop_category == "context_thrash"
      assert row.terminal_lines == []
      refute row.transcript_read?
      assert meta.transcript_reads == 0
      assert meta.failed_runs == 1

      # And the classification is still correct without any transcript.
      result =
        Arbiter.Loop.FailureClassifier.classify(row.failure_reason, row.terminal_lines,
          stop_category: row.stop_category
        )

      assert result.class == :agent_quality
      assert result.subcategory == :context_exhaustion
      assert result.evidence == :stop_category
    end

    test "a run with no stop_category still gets its bounded transcript read" do
      run = failed_run("bd-corpus-untyped", %{failure_reason: "claude session error"})
      write_log(run.id, ["Autocompact is thrashing"])

      assert {:ok, [row], meta} = Corpus.fetch(window())

      assert row.stop_category == nil
      assert Enum.any?(row.terminal_lines, &String.contains?(&1, "Autocompact"))
      assert meta.transcript_reads == 1
    end

    test "an inconclusive stop_category (:crashed) still gets its transcript read" do
      run =
        failed_run("bd-corpus-crashed", %{
          failure_reason: "agent subprocess crashed (exit code 1)",
          stop_category: "crashed"
        })

      write_log(run.id, ["** (DBConnection.ConnectionError) boom"])

      assert {:ok, [row], meta} = Corpus.fetch(window())

      assert Enum.any?(row.terminal_lines, &String.contains?(&1, "DBConnection"))
      assert meta.transcript_reads == 1
    end

    # `transcript_reads` is documented as "how much of itself still had to be
    # text-mined". Counting rows whose read *returned lines* scores a blind
    # window (output log reaped) identically to a fully-structured one.
    test "a reaped output log still counts as a transcript read" do
      _run = failed_run("bd-corpus-reaped", %{failure_reason: "claude session error"})
      # No write_log/2 — the log is gone, so the bounded read returns nothing.

      assert {:ok, [row], meta} = Corpus.fetch(window())

      assert row.terminal_lines == []
      assert row.transcript_read?
      assert meta.transcript_reads == 1
      assert meta.failed_runs == 1
    end

    test "a completed run is never read and never counted" do
      {:ok, _run} =
        Ash.create(Run, %{
          task_id: "bd-corpus-ok",
          repo: "arbiter",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      assert {:ok, [row], meta} = Corpus.fetch(window())
      assert row.terminal_lines == []
      assert meta.failed_runs == 0
      assert meta.transcript_reads == 0
    end
  end

  describe "record_pass_cost/1 — the pass's single ledger write" do
    test "inserts one usage_events row for the pass itself (step :other)" do
      before = count_events()

      id =
        Corpus.record_pass_cost(%{duration_ms: 1234, rows_scanned: 42, workspace_id: nil})

      assert is_binary(id)
      assert count_events() == before + 1

      %{rows: [[task_id, step, model]]} =
        Repo.query!(
          "SELECT task_id, step, model FROM usage_events WHERE id = ?1",
          [id]
        )

      assert task_id == "loop-analyze"
      assert step == "other"
      assert model == "loop-analysis-pass"
    end
  end

  describe "fetch/1 — bounded window read" do
    test "an empty window yields no rows and a well-formed meta" do
      since = ~U[2000-01-01 00:00:00Z]
      until = ~U[2000-01-08 00:00:00Z]

      assert {:ok, [], meta} = Corpus.fetch(since: since, until: until, label: "ancient")
      assert meta.label == "ancient"
      assert meta.since == since
      assert meta.until == until
    end

    # #1221: duplicate-dispatch clustering keys on the task's title, so the
    # corpus fetch must surface it (it's already denormalised onto
    # worker_runs.task_title for the dashboard's history list).
    test "surfaces the run's task_title as :title" do
      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _run} =
        Ash.create(Run, %{
          task_id: "lt-6glz4n",
          repo: "verus_server",
          task_title: "PR #3701: chore: merge integration/dolphin i…",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, [row], _meta} = Corpus.fetch(since: since, until: until)
      assert row.title == "PR #3701: chore: merge integration/dolphin i…"
    end
  end

  defp count_events do
    %{rows: [[n]]} = Repo.query!("SELECT COUNT(*) FROM usage_events", [])
    n
  end

  # bd-5ja2vb: `Arbiter.Loop.Analysis.bucket_finding/1` (now
  # `Arbiter.Loop.FindingBuckets.bucket_finding/1`) is a four-regex allowlist —
  # a reviewer finding matching none of them was previously dropped, uncounted,
  # by `Enum.reject(&is_nil/1)`. `Corpus.fetch/1` must count and retain that
  # residue in `meta.finding_residue`, symmetric with `failed_runs` /
  # `transcript_reads` above.
  describe "fetch/1 — finding residue (bd-5ja2vb)" do
    alias Arbiter.ReviewGate.Round

    defp review_round!(task_id, attrs) do
      {:ok, round} =
        Ash.create(
          Round,
          Map.merge(
            %{
              task_id: task_id,
              round: 1,
              role: :review,
              verdict: :request_changes,
              converged: false
            },
            attrs
          )
        )

      round
    end

    test "a finding matching no bucket is counted and retained, with its task_id/run_id" do
      round =
        review_round!("bd-residue-1", %{
          run_id: "11111111-1111-1111-1111-111111111111",
          findings:
            "1. The memoisation key omits the tenant id, so two tenants share a cache slot."
        })

      assert {:ok, [], meta} = Corpus.fetch(window())

      assert meta.finding_residue.total_units == 1
      assert meta.finding_residue.count == 1
      assert meta.finding_residue.rate == 1.0
      assert meta.finding_residue.distinct_tasks == 1
      assert [unit] = meta.finding_residue.units
      assert unit.task_id == "bd-residue-1"
      assert unit.run_id == round.run_id
      assert unit.text =~ "memoisation key"
    end

    test "a finding matching a bucket is NOT residue, but still counts toward total_units" do
      review_round!("bd-residue-2", %{
        findings: "1. No test covers the new branch."
      })

      assert {:ok, [], meta} = Corpus.fetch(window())

      assert meta.finding_residue.total_units == 1
      assert meta.finding_residue.count == 0
      assert meta.finding_residue.rate == 0.0
      assert meta.finding_residue.units == []
    end

    test "an approve round's findings are excluded entirely" do
      review_round!("bd-residue-3", %{
        verdict: :approve,
        converged: true,
        findings: "1. Nitpick: the memoisation key naming could be clearer."
      })

      assert {:ok, [], meta} = Corpus.fetch(window())

      assert meta.finding_residue.total_units == 0
      assert meta.finding_residue.count == 0
      assert meta.finding_residue.rate == nil
    end

    test "an empty window reports a well-formed zero-shape, not a crash" do
      assert {:ok, [], meta} =
               Corpus.fetch(since: ~U[2000-01-01 00:00:00Z], until: ~U[2000-01-08 00:00:00Z])

      assert meta.finding_residue == %{
               total_units: 0,
               count: 0,
               rate: nil,
               distinct_tasks: 0,
               units: []
             }
    end

    test "two residue findings across two tasks count two distinct tasks" do
      review_round!("bd-residue-4", %{findings: "1. stale memoisation key on refresh"})
      review_round!("bd-residue-5", %{findings: "1. cache key omits the shard id"})

      assert {:ok, [], meta} = Corpus.fetch(window())

      assert meta.finding_residue.count == 2
      assert meta.finding_residue.distinct_tasks == 2
    end

    test "a retained unit's text is truncated to residue_text_limit/0 characters" do
      long_text = "1. " <> String.duplicate("x", Corpus.residue_text_limit() + 100)
      review_round!("bd-residue-6", %{findings: long_text})

      assert {:ok, [], meta} = Corpus.fetch(window())
      assert [unit] = meta.finding_residue.units
      # +1 for the trailing ellipsis marker.
      assert String.length(unit.text) == Corpus.residue_text_limit() + 1
    end
  end
end
