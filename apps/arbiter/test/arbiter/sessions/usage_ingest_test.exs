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

    test "a file without cost-state still records tokens, with a null cost" do
      dir = tmp_dir!("ingest-nocost")
      sid = "sess-#{System.unique_integer([:positive])}"
      write!(dir, sid, [turn(sid, "m1", now(), 10, 100)])

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir])
      assert [ev] = rows_for(sid)
      assert ev.cost_usd == nil
      assert is_binary(ev.cost_note)
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

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :coordinator_session_dirs, prior),
          else: Application.delete_env(:arbiter, :coordinator_session_dirs)
      end)

      assert {:ok, %{rows_written: 1}} = UsageIngest.ingest()
      assert [_ev] = rows_for(sid)
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

      log = capture_log(fn -> assert {:ok, %{rows_written: 1}} = UsageIngest.ingest(dirs: [dir]) end)

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
end
