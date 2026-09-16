defmodule Arbiter.Sessions.UsageIngestTest do
  # DataCase + async: false — these tests mutate the :arbiter application env
  # for :coordinator_session_dirs and read the shared ledger table.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Sessions.UsageIngest
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp rows_for(session_id) do
    Event
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  # One `assistant` turn plus (optionally) the CLI's own `cost-state` record —
  # the two record types the ingest is allowed to look at. `sid` is stamped on
  # every line the way the real files do, so the rollover guard has something
  # to judge.
  defp turn(sid, msg_id, at, tokens_in, tokens_out) do
    ~s({"type":"assistant","timestamp":"#{DateTime.to_iso8601(at)}","sessionId":"#{sid}","message":{"id":"#{msg_id}","model":"claude-opus-5","usage":{"input_tokens":#{tokens_in},"output_tokens":#{tokens_out},"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}})
  end

  defp cost_state(sid, cost, start_ms, duration_ms \\ 1000) do
    ~s({"type":"cost-state","sessionId":"#{sid}","totalCostUSD":#{cost},"totalDuration":#{duration_ms},"startTime":#{start_ms},"modelUsage":{"claude-opus-5":{"costUSD":#{cost}}}})
  end

  defp write!(dir, sid, lines, mode \\ [:write]) do
    File.write!(Path.join(dir, sid <> ".jsonl"), Enum.join(lines, "\n") <> "\n", mode)
  end

  defp now, do: DateTime.utc_now()
  defp start_ms, do: DateTime.to_unix(now(), :millisecond)

  describe "ingest/1" do
    test "writes one coordinator_session row per session file" do
      dir = tmp_dir!("ingest")
      sid = "sess-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 10, 100), cost_state(sid, 2.5, start_ms())])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      assert [ev] = rows_for(sid)
      assert ev.source == :coordinator_session
      assert ev.task_id == nil
      assert ev.session_id == sid
      assert ev.provider == "claude"
      assert ev.model == "claude-opus-5"
      assert ev.tokens_in == 10
      assert ev.tokens_out == 100
      assert_in_delta ev.cost_usd, 2.5, 0.0000001
    end

    test "running twice over unchanged files writes no duplicate" do
      dir = tmp_dir!("ingest-idem")
      sid = "sess-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 10, 100), cost_state(sid, 2.5, start_ms())])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert {:ok, %{rows_written: 0}} = UsageIngest.ingest(dirs: [dir])

      assert [_single] = rows_for(sid)
    end

    test "a file appended between runs is billed only for the appended delta" do
      dir = tmp_dir!("ingest-append")
      sid = "sess-#{System.unique_integer([:positive])}"
      started = start_ms()
      write!(dir, sid, [turn(sid, "m1", now(), 10, 100), cost_state(sid, 2.5, started)])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      # A later turn, and the CLI's updated running total for the same process.
      write!(dir, sid, [turn(sid, "m2", now(), 7, 70), cost_state(sid, 4.0, started)], [:append])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      assert [first, second] = rows_for(sid)
      assert first.tokens_in == 10
      assert second.tokens_in == 7, "the second row bills the delta, not the running total"
      assert second.tokens_out == 70
      assert_in_delta second.cost_usd, 1.5, 0.0000001
      assert Enum.sum(Enum.map([first, second], & &1.tokens_in)) == 17
    end

    test "a --resume rollover into a new session id does not re-bill the copied lines" do
      # The CLI can roll a session onto a NEW id and copy the transcript into
      # the new file. Those copies keep the PARENT's `sessionId`; billing them
      # under the child would double-count the whole parent session.
      dir = tmp_dir!("ingest-rollover")
      parent = "sess-parent-#{System.unique_integer([:positive])}"
      child = "sess-child-#{System.unique_integer([:positive])}"
      parent_start = start_ms()

      write!(dir, parent, [
        turn(parent, "p1", now(), 1000, 9000),
        cost_state(parent, 42.0, parent_start)
      ])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [parent_row] = rows_for(parent)
      assert parent_row.tokens_in == 1000

      # Rollover: the parent's lines are copied verbatim into the child file,
      # then the child's own turns are appended.
      write!(dir, child, [
        turn(parent, "p1", now(), 1000, 9000),
        cost_state(parent, 42.0, parent_start),
        turn(child, "c1", now(), 5, 50),
        cost_state(child, 0.25, start_ms() + 1)
      ])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      assert [child_row] = rows_for(child)
      assert child_row.tokens_in == 5, "the parent's copied turn must not be billed again"
      assert_in_delta child_row.cost_usd, 0.25, 0.0000001

      # And the parent's own row is untouched.
      assert [^parent_row] = rows_for(parent)
    end

    test "a file with no usage at all writes nothing" do
      dir = tmp_dir!("ingest-empty")
      sid = "sess-#{System.unique_integer([:positive])}"
      File.write!(Path.join(dir, sid <> ".jsonl"), ~s({"type":"user","message":{}}) <> "\n")

      assert {:ok, %{rows_written: 0}} = UsageIngest.ingest(dirs: [dir])
      assert rows_for(sid) == []
    end

    test "a file without cost-state is priced from its tokens" do
      # Claude Code 2.1.270 writes no `cost-state` record at all, which left
      # every coordinator row at `cost_usd: nil` after the first deploy.
      # claude-opus-5: 10 in ($5/MTok) + 100 out ($25/MTok).
      dir = tmp_dir!("ingest-nocost")
      sid = "sess-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 10, 100)])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [ev] = rows_for(sid)
      assert_in_delta ev.cost_usd, 0.00255, 0.0000001
      assert ev.cost_note =~ "estimated from tokens (no cost-state)"
      assert ev.tokens_in == 10
    end

    test "a file without cost-state on an unpriceable model keeps a null cost" do
      dir = tmp_dir!("ingest-nocost-unknown")
      sid = "sess-#{System.unique_integer([:positive])}"

      write!(dir, sid, [
        ~s({"type":"assistant","timestamp":"#{DateTime.to_iso8601(now())}","sessionId":"#{sid}","message":{"id":"m1","model":"some-other-vendor-model","usage":{"input_tokens":10,"output_tokens":100}}})
      ])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [ev] = rows_for(sid)
      assert ev.cost_usd == nil
      assert ev.cost_note =~ "no cost-state"
      assert ev.tokens_in == 10
    end

    test "an unconfigured install is a no-op, not an error" do
      assert {:ok, %{files: 0, rows_written: 0}} = UsageIngest.ingest(dirs: [])
    end

    test "a missing directory is skipped, not fatal" do
      assert {:ok, %{files: 0, rows_written: 0}} =
               UsageIngest.ingest(dirs: [Path.join(System.tmp_dir!(), "definitely-not-here")])
    end

    test "falls back to the configured directories when none are passed" do
      dir = tmp_dir!("ingest-cfg")
      sid = "sess-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 3, 4)])

      prior = Application.get_env(:arbiter, :coordinator_session_dirs)
      Application.put_env(:arbiter, :coordinator_session_dirs, [dir])

      # On the dogfood host ARBITER_COORDINATOR_SESSION_DIRS is really set, and
      # it outranks the app env — without this the test sweeps the operator's
      # own ~/.claude transcripts instead of its fixture.
      prior_env = System.get_env("ARBITER_COORDINATOR_SESSION_DIRS")
      System.delete_env("ARBITER_COORDINATOR_SESSION_DIRS")

      on_exit(fn ->
        if prior_env, do: System.put_env("ARBITER_COORDINATOR_SESSION_DIRS", prior_env)

        if prior,
          do: Application.put_env(:arbiter, :coordinator_session_dirs, prior),
          else: Application.delete_env(:arbiter, :coordinator_session_dirs)
      end)

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest()
      assert [_ev] = rows_for(sid)
    end

    test "sweeps a browser-hosted session's config_dir, two levels deeper than a coordinator dir" do
      config_dir = tmp_dir!("browser-session")
      project_dir = Path.join(config_dir, "projects/-home-ryan-dev-admiral")
      File.mkdir_p!(project_dir)
      sid = "sess-#{System.unique_integer([:positive])}"

      write!(project_dir, sid, [
        turn(sid, "m1", now(), 10, 100),
        cost_state(sid, 2.5, start_ms())
      ])

      assert {:ok, %{rows_written: 1}} =
               UsageIngest.ingest(dirs: [], sessions: [%{config_dir: config_dir}])

      assert [ev] = rows_for(sid)
      assert ev.session_id == sid
      assert_in_delta ev.cost_usd, 2.5, 0.0000001
    end
  end

  describe "privacy" do
    # AC4. The ingest is allowed to read `usage`, `cost-state` and identifying
    # metadata and nothing else. Nothing token-like or human-authored may reach
    # the DB or the log — a metering feature that quietly copies transcripts
    # into the ledger is a worse bug than the missing metering it fixes.
    @secret "sk-ant-oat01-NOTAREALTOKEN-abcdefghijklmnop"
    @prompt "the operator asked about the acme merger codename BLUEBIRD"
    @tool_input "/home/ryan/.ssh/id_ed25519"
    @tool_output "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI-not-a-real-key"

    test "no message content, tool input/output or secret reaches the DB or the log" do
      dir = tmp_dir!("ingest-privacy")
      sid = "sess-privacy-#{System.unique_integer([:positive])}"
      at = DateTime.to_iso8601(now())

      lines = [
        ~s({"type":"user","timestamp":"#{at}","sessionId":"#{sid}","message":{"role":"user","content":#{Jason.encode!(@prompt <> " " <> @secret)}}}),
        ~s({"type":"assistant","timestamp":"#{at}","sessionId":"#{sid}","message":{"id":"m1","model":"claude-opus-5","content":[{"type":"text","text":#{Jason.encode!(@prompt)}},{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":#{Jason.encode!(@tool_input)}}}],"usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}),
        ~s({"type":"user","timestamp":"#{at}","sessionId":"#{sid}","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":#{Jason.encode!(@tool_output)}}]}}),
        cost_state(sid, 1.0, start_ms())
      ]

      write!(dir, sid, lines)

      log =
        capture_log(fn -> assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir]) end)

      assert [ev] = rows_for(sid)
      haystack = inspect(Map.from_struct(ev), limit: :infinity, printable_limit: :infinity)

      for needle <- [@secret, @prompt, @tool_input, @tool_output] do
        refute haystack =~ needle, "the ledger row leaked #{inspect(needle)}"
        refute log =~ needle, "the log leaked #{inspect(needle)}"
      end

      # And the row is still a real, useful metering row.
      assert ev.tokens_in == 10
      assert_in_delta ev.cost_usd, 1.0, 0.0000001
    end
  end

  describe "arb usage rollups" do
    # AC5. Session rows are spend with no task, so they must appear under
    # `--by source` and stay out of `--by task` — the same rule every other
    # task-less source already follows.
    test "--by source shows coordinator_session; --by task ignores it" do
      dir = tmp_dir!("ingest-rollup")
      sid = "sess-rollup-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 11, 111), cost_state(sid, 6.0, start_ms())])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      since = DateTime.add(now(), -1, :day)

      {:ok, by_source} = Usage.summarize(by: :source, since: since)
      row = Enum.find(by_source, &(&1.group == "coordinator_session"))
      assert row, "--by source must show a coordinator_session row"
      assert row.total_cost_usd >= 6.0
      assert row.tokens_in >= 11

      {:ok, by_task} = Usage.summarize(by: :task, since: since)
      refute Enum.any?(by_task, &(&1.group == nil or &1.group == sid))
    end
  end

  describe "occurred_at" do
    # The first deploy dated every backfilled row at ingest time, so a session
    # that had been running for ten days landed as one lump on the ingest day
    # and `arb usage --by day` was simply wrong. Rows are dated from the
    # transcript instead, and a delta that spans midnight UTC splits.
    test "a row is dated from the session's own turn timestamps, not the clock" do
      dir = tmp_dir!("ingest-when")
      sid = "sess-when-#{System.unique_integer([:positive])}"
      at = ~U[2026-09-10 14:22:33.000Z]

      write!(dir, sid, [turn(sid, "m1", at, 10, 100)])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [ev] = rows_for(sid)
      assert DateTime.to_date(ev.occurred_at) == ~D[2026-09-10]
      assert DateTime.compare(ev.occurred_at, at) == :eq
    end

    test "a session spanning UTC days writes one row per day" do
      dir = tmp_dir!("ingest-days")
      sid = "sess-days-#{System.unique_integer([:positive])}"
      started = 1_788_000_000_000

      write!(dir, sid, [
        turn(sid, "m1", ~U[2026-09-10 23:50:00.000Z], 10, 100),
        turn(sid, "m2", ~U[2026-09-11 00:10:00.000Z], 20, 200),
        cost_state(sid, 3.0, started)
      ])

      assert {:ok, %{rows_written: 2}} = UsageIngest.ingest(dirs: [dir])

      rows = rows_for(sid) |> Enum.sort_by(& &1.occurred_at, DateTime)
      assert [tenth, eleventh] = rows
      assert DateTime.to_date(tenth.occurred_at) == ~D[2026-09-10]
      assert DateTime.to_date(eleventh.occurred_at) == ~D[2026-09-11]
      assert tenth.tokens_out == 100
      assert eleventh.tokens_out == 200

      # The CLI's own $3.00 is apportioned, never inflated.
      assert_in_delta tenth.cost_usd + eleventh.cost_usd, 3.0, 0.0000001

      # ...and the whole thing is still idempotent day-by-day.
      assert {:ok, %{rows_written: 0}} = UsageIngest.ingest(dirs: [dir])
      assert length(rows_for(sid)) == 2
    end

    test "an append to an already-billed day bills that day, not today" do
      dir = tmp_dir!("ingest-days-append")
      sid = "sess-days-append-#{System.unique_integer([:positive])}"

      write!(dir, sid, [turn(sid, "m1", ~U[2026-09-10 08:00:00.000Z], 10, 100)])
      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      write!(dir, sid, [turn(sid, "m2", ~U[2026-09-10 09:00:00.000Z], 5, 50)], [:append])
      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      rows = rows_for(sid) |> Enum.sort_by(& &1.occurred_at, DateTime)
      assert [first, second] = rows
      assert DateTime.to_date(first.occurred_at) == ~D[2026-09-10]
      assert DateTime.to_date(second.occurred_at) == ~D[2026-09-10]
      assert second.tokens_out == 50, "the second row bills the delta for that day only"
      assert DateTime.compare(second.occurred_at, ~U[2026-09-10 09:00:00.000Z]) == :eq
    end

    # `totalDuration` is cumulative on disk like every other figure in
    # `cost-state`. A sweep that re-billed it in full would inflate the
    # `duration_ms` column of every `Usage.summarize/1` rollup once per cycle —
    # dozens of times over a busy day on the live host's 5-minute sweeper.
    test "duration_ms is billed as a delta, not re-billed on every cycle" do
      dir = tmp_dir!("ingest-duration")
      sid = "sess-dur-#{System.unique_integer([:positive])}"
      at = ~U[2026-09-10 08:00:00.000Z]

      # One `startTime` throughout: this is a single CLI process appending to
      # its own transcript, so both figures below are cumulative, not additive.
      started = start_ms()

      write!(dir, sid, [turn(sid, "m1", at, 10, 100), cost_state(sid, 2.5, started, 1000)])
      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      write!(
        dir,
        sid,
        [
          turn(sid, "m2", DateTime.add(at, 3600), 5, 50),
          cost_state(sid, 5.0, started, 2000)
        ],
        [:append]
      )

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])

      rows = rows_for(sid)
      assert length(rows) == 2

      assert Enum.sum(Enum.map(rows, &(&1.duration_ms || 0))) == 2000,
             "the ledger must sum to the file's totalDuration, not a multiple of it"

      assert_in_delta Enum.sum(Enum.map(rows, & &1.cost_usd)), 5.0, 0.0000001
    end

    # A file with no parseable timestamps is dated `now` and holds the whole
    # file's cumulative totals, so today's ledger stops being the right
    # watermark the moment the UTC day rolls over. Its watermark is the whole
    # session's ledger instead.
    test "an undated transcript is not re-billed when the UTC day rolls over" do
      dir = tmp_dir!("ingest-undated")
      sid = "sess-undated-#{System.unique_integer([:positive])}"

      undated =
        ~s({"type":"assistant","sessionId":"#{sid}","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}})

      write!(dir, sid, [undated, cost_state(sid, 0.055, start_ms())])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [ev] = rows_for(sid)

      # Stand in for the sweeper's next run landing after midnight UTC: the row
      # it already wrote is no longer filed under `Date.utc_today()`.
      import Ecto.Query, only: [from: 2]

      {1, _} =
        Arbiter.Repo.update_all(
          from(e in Event, where: e.id == ^ev.id),
          set: [occurred_at: DateTime.add(ev.occurred_at, -1, :day)]
        )

      assert {:ok, %{rows_written: 0}} = UsageIngest.ingest(dirs: [dir])
      assert length(rows_for(sid)) == 1
    end

    test "a real v2.1.270 transcript backfills its two days at their own dates" do
      fixture =
        Path.expand(
          "../../fixtures/claude_sessions/coordinator_session_v2_1_270.jsonl",
          __DIR__
        )

      dir = tmp_dir!("ingest-v270")
      # The file has to keep its own session id: every line is stamped with it,
      # and the rollover guard drops lines stamped with another session's.
      sid = "202434c2-72ab-4aff-a715-57375729d810"
      File.cp!(fixture, Path.join(dir, sid <> ".jsonl"))

      assert {:ok, %{rows_written: 2}} = UsageIngest.ingest(dirs: [dir])

      rows = rows_for(sid) |> Enum.sort_by(& &1.occurred_at, DateTime)

      assert Enum.map(rows, &DateTime.to_date(&1.occurred_at)) == [
               ~D[2026-09-13],
               ~D[2026-09-14]
             ]

      # No `cost-state` anywhere in that file, and yet both rows carry money.
      assert Enum.all?(rows, &(&1.cost_usd > 0))
      assert Enum.all?(rows, &(&1.cost_note =~ "estimated from tokens (no cost-state)"))
      assert_in_delta Enum.sum(Enum.map(rows, & &1.cost_usd)), 3.0781575, 0.0000001

      assert {:ok, %{rows_written: 0}} = UsageIngest.ingest(dirs: [dir])
    end
  end
end
