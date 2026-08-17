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
end
