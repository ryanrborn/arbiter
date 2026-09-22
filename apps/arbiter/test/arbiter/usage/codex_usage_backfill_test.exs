defmodule Arbiter.Usage.CodexUsageBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage.CodexUsageBackfill
  alias Arbiter.Usage.Event

  defp create_event!(attrs) do
    base = %{
      provider: "codex",
      source: :preflight,
      step: :other,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  defp write_rollout!(sessions_dir, date, session_id, timestamp, tokens_in, cached, tokens_out) do
    dir =
      Path.join([
        sessions_dir,
        pad(date.year, 4),
        pad(date.month, 2),
        pad(date.day, 2)
      ])

    File.mkdir_p!(dir)
    path = Path.join(dir, "rollout-#{session_id}.jsonl")

    # Envelope confirmed live against installed codex-cli 0.153.4 — see
    # `Arbiter.Usage.CodexSessionFileTest` for the full match against a real
    # rollout file.
    lines = [
      ~s({"timestamp":"#{timestamp}","ordinal":0,"type":"session_meta",) <>
        ~s("payload":{"session_id":"#{session_id}","timestamp":"#{timestamp}"}}),
      ~s({"timestamp":"#{timestamp}","ordinal":1,"type":"event_msg",) <>
        ~s("payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":#{tokens_in},) <>
        ~s("cached_input_tokens":#{cached},"cache_write_input_tokens":0,) <>
        ~s("output_tokens":#{tokens_out},"reasoning_output_tokens":0}}}})
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp pad(n, len), do: n |> Integer.to_string() |> String.pad_leading(len, "0")

  defp tmp_sessions_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "codex-usage-backfill-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "backfill/1" do
    test "dry-run reports what it would write and does not touch the row" do
      dir = tmp_sessions_dir()
      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      write_rollout!(
        dir,
        ~D[2026-09-17],
        "sid-dry",
        "2026-09-17T00:04:32.619Z",
        18_915,
        18_176,
        5
      )

      ev =
        create_event!(%{
          occurred_at: occurred_at,
          duration_ms: 4505,
          tokens_in: nil,
          tokens_out: nil
        })

      report = CodexUsageBackfill.backfill(sessions_dir: dir)

      assert report.scanned == 1
      assert report.would_backfill == 1
      assert report.backfilled == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
    end

    test "--apply writes recovered tokens and a provenance cost_note" do
      dir = tmp_sessions_dir()
      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      write_rollout!(
        dir,
        ~D[2026-09-17],
        "sid-apply",
        "2026-09-17T00:04:32.619Z",
        18_915,
        18_176,
        5
      )

      ev =
        create_event!(%{
          occurred_at: occurred_at,
          duration_ms: 4505,
          tokens_in: nil,
          tokens_out: nil
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)

      assert report.scanned == 1
      assert report.backfilled == 1

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == 18_915
      assert reloaded.tokens_out == 5
      assert reloaded.cache_read_tokens == 18_176
      assert reloaded.cost_note =~ "backfilled from on-disk codex rollout JSONL"
      # Cost stays unknown — codex is metered, not billed per call.
      assert reloaded.cost_usd == nil
    end

    test "a row already carrying tokens is never touched (idempotent)" do
      dir = tmp_sessions_dir()

      ev =
        create_event!(%{
          occurred_at: DateTime.utc_now(),
          tokens_in: 42,
          tokens_out: 7
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)
      assert report.scanned == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == 42
    end

    test "a row with no matching rollout is counted, not silently dropped, and gets an honest note" do
      dir = tmp_sessions_dir()

      ev =
        create_event!(%{
          occurred_at: DateTime.utc_now(),
          exit_status: 0,
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (the CLI returned no parseable result object)"
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)
      assert report.scanned == 1
      assert report.no_rollout_file == 1
      assert report.backfilled == 0

      # bd-96mn8i round 5 finding 2: the disproven pre-fix note ("CLI
      # reported nothing") must not survive an --apply pass on a row this
      # backfill couldn't recover — it gets a note admitting the real cause
      # (unrecoverable, not "nothing to recover"). This row completed
      # (`exit_status: 0`), so the "parser dropped it" story holds.
      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
      assert reloaded.cost_note =~ "unrecoverable"
      refute reloaded.cost_note =~ "CLI returned no parseable result object"
    end

    test "a dry-run leaves a row with no matching rollout untouched" do
      dir = tmp_sessions_dir()

      ev =
        create_event!(%{
          occurred_at: DateTime.utc_now(),
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (the CLI returned no parseable result object)"
        })

      report = CodexUsageBackfill.backfill(sessions_dir: dir)
      assert report.no_rollout_file == 1

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.cost_note =~ "CLI returned no parseable result object"
    end

    test "a source: :task row is never scanned or rewritten, even with nil tokens and a matching rollout" do
      dir = tmp_sessions_dir()
      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      # A rollout exists and would match on timestamp alone — this proves
      # the exclusion is the `source` filter, not "no rollout found".
      write_rollout!(
        dir,
        ~D[2026-09-17],
        "sid-task",
        "2026-09-17T00:04:32.619Z",
        18_915,
        18_176,
        5
      )

      worker_note =
        "a terminal event was observed (status: error), but it reported no usage payload"

      ev =
        create_event!(%{
          source: :task,
          task_id: Ash.UUID.generate(),
          occurred_at: occurred_at,
          duration_ms: 4505,
          tokens_in: nil,
          tokens_out: nil,
          cost_note: worker_note
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)

      assert report.scanned == 0
      assert report.backfilled == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
      assert reloaded.cost_note == worker_note
    end

    test "a row from a failed (non-zero exit) probe gets a 'never reported' note, not a 'parser dropped it' note" do
      dir = tmp_sessions_dir()

      ev =
        create_event!(%{
          occurred_at: DateTime.utc_now(),
          exit_status: 1,
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (the CLI returned no parseable result object)"
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)
      assert report.no_rollout_file == 1

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
      assert reloaded.cost_note =~ "usage unknown"
      assert reloaded.cost_note =~ "exited non-zero or timed out"
      refute reloaded.cost_note =~ "pre-fix Probe.parse/1 bug lost"
    end

    test "a row from a probe with no recorded exit_status (timeout) also gets the 'never reported' note" do
      dir = tmp_sessions_dir()

      ev =
        create_event!(%{
          occurred_at: DateTime.utc_now(),
          exit_status: nil,
          tokens_in: nil,
          tokens_out: nil
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)
      assert report.no_rollout_file == 1

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.cost_note =~ "usage unknown"
      refute reloaded.cost_note =~ "pre-fix Probe.parse/1 bug lost"
    end

    test "a matched rollout with no token_count line is counted separately and gets an honest note" do
      dir = tmp_sessions_dir()
      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      dated_dir = Path.join([dir, "2026", "09", "17"])
      File.mkdir_p!(dated_dir)

      File.write!(
        Path.join(dated_dir, "rollout-sid-nousage.jsonl"),
        ~s({"type":"session_meta","payload":{"session_id":"sid-nousage",) <>
          ~s("timestamp":"2026-09-17T00:04:32.619Z"}}) <> "\n"
      )

      ev =
        create_event!(%{
          occurred_at: occurred_at,
          duration_ms: 4505,
          exit_status: 0,
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (the CLI returned no parseable result object)"
        })

      report = CodexUsageBackfill.backfill(apply?: true, sessions_dir: dir)
      assert report.no_token_count == 1
      assert report.backfilled == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
      assert reloaded.cost_note =~ "unrecoverable"
      refute reloaded.cost_note =~ "CLI returned no parseable result object"
    end
  end
end
