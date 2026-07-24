defmodule Arbiter.Usage.ClaudeSessionFileTest do
  # Pure filesystem/parse module — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Arbiter.Usage.ClaudeSessionFile, as: SessionFile

  # A hand-built session JSONL with the streaming-duplication the spike found:
  # two consecutive `assistant` lines share message.id "msg-1" with identical
  # usage (a re-emitted streaming snapshot, NOT incremental), so a naive sum
  # double-counts. The deduped (keep-first, by message.id) totals are:
  #   input=15  output=300  cache_read=3000  cache_creation=110  (2 messages)
  #
  # Timestamps mirror the real files (ISO8601 with a Z offset) and are spread
  # across a two-run window: msg-1 lands at 20:50 (an earlier run's turn),
  # msg-2 at 23:32 — the shape `--resume` produces when it appends a second
  # run's turns to the first run's file.
  @lines [
    ~s({"type":"system","subtype":"init","session_id":"SID","model":"claude-opus-4-8"}),
    ~s({"type":"user","message":{"role":"user","content":"hi"}}),
    ~s({"type":"assistant","timestamp":"2026-07-01T20:50:00.100Z","requestId":"req-1","uuid":"u-1a","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
    ~s({"type":"assistant","timestamp":"2026-07-01T20:50:00.600Z","requestId":"req-1","uuid":"u-1b","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
    ~s(),
    ~s({"type":"assistant","timestamp":"2026-07-01T23:32:10.000Z","requestId":"req-2","uuid":"u-2","message":{"id":"msg-2","model":"claude-opus-4-8","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":2000,"cache_creation_input_tokens":60}}}),
    ~s({"type":"result","subtype":"success","total_cost_usd":0.42})
  ]

  defp write_session!(config_dir, cwd, session_id) do
    slug = SessionFile.project_slug(cwd)
    dir = Path.join([config_dir, "projects", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, session_id <> ".jsonl")
    File.write!(path, Enum.join(@lines, "\n") <> "\n")
    path
  end

  describe "project_slug/1" do
    test "replaces every non-alphanumeric char with a dash (Claude Code's rule)" do
      assert SessionFile.project_slug("/home/ryan/dev/arbiter-worktrees/feature-967") ==
               "-home-ryan-dev-arbiter-worktrees-feature-967"
    end

    test "dots and underscores are replaced too; case preserved" do
      assert SessionFile.project_slug("/tmp/tmp.AbC_1") == "-tmp-tmp-AbC-1"
    end
  end

  describe "read_totals/1" do
    test "dedupes streaming re-emits by message.id and sums token buckets" do
      dir = tmp_dir()
      path = write_session!(dir, "/work/tree", "SID")

      assert {:ok, totals} = SessionFile.read_totals(path)
      assert totals.tokens_in == 15
      assert totals.tokens_out == 300
      assert totals.cache_read_tokens == 3000
      assert totals.cache_creation_tokens == 110
      assert totals.message_count == 2
      assert totals.model == "claude-opus-4-8"
    end

    test "missing file is an error, not a crash" do
      assert {:error, _} = SessionFile.read_totals(Path.join(tmp_dir(), "nope.jsonl"))
    end

    test "a file with no assistant usage returns zeroed totals" do
      dir = tmp_dir()
      path = Path.join(dir, "empty.jsonl")
      File.write!(path, ~s({"type":"user","message":{}}) <> "\n")
      assert {:ok, totals} = SessionFile.read_totals(path)
      assert totals.message_count == 0
      assert totals.tokens_in == 0
      assert totals.skipped_before_since == 0
    end
  end

  # `--resume <sid>` appends a second run's turns to the FIRST run's file, but
  # Arbiter opens a new Workers.Run row for the resumed attempt. Without a
  # cutoff the child run would be billed for everything its parent spent.
  describe "read_totals/2 with :since (resume-shared file)" do
    test "counts only turns at or after the cutoff" do
      dir = tmp_dir()
      path = write_session!(dir, "/work/tree", "SID")

      # The resumed run started at 23:30 — only msg-2 (23:32) is its own.
      assert {:ok, totals} =
               SessionFile.read_totals(path, since: ~U[2026-07-01 23:30:00.000000Z])

      assert totals.tokens_in == 5
      assert totals.tokens_out == 200
      assert totals.cache_read_tokens == 2000
      assert totals.cache_creation_tokens == 60
      assert totals.message_count == 1
      assert totals.skipped_before_since == 1, "the parent run's turn is excluded"
    end

    test "a cutoff before every turn still sums the whole file" do
      dir = tmp_dir()
      path = write_session!(dir, "/work/tree", "SID")

      assert {:ok, totals} =
               SessionFile.read_totals(path, since: ~U[2026-07-01 20:00:00.000000Z])

      assert totals.tokens_in == 15
      assert totals.tokens_out == 300
      assert totals.message_count == 2
      assert totals.skipped_before_since == 0
    end

    test "a cutoff after every turn yields zeroed totals (nothing to reconcile)" do
      dir = tmp_dir()
      path = write_session!(dir, "/work/tree", "SID")

      assert {:ok, totals} =
               SessionFile.read_totals(path, since: ~U[2026-07-02 00:00:00.000000Z])

      assert totals.message_count == 0
      assert totals.tokens_in == 0
      assert totals.skipped_before_since == 2
    end

    test "a streaming re-emit straddling the cutoff cannot smuggle the earlier turn in" do
      # msg-1's first line is before the cutoff; its re-emit lands after. The
      # turn belongs to the parent run and must stay excluded either way.
      dir = tmp_dir()
      path = Path.join(dir, "straddle.jsonl")

      File.write!(
        path,
        Enum.join(
          [
            ~s({"type":"assistant","timestamp":"2026-07-01T22:59:59.000Z","message":{"id":"msg-1","usage":{"input_tokens":1000,"output_tokens":9000}}}),
            ~s({"type":"assistant","timestamp":"2026-07-01T23:00:01.000Z","message":{"id":"msg-1","usage":{"input_tokens":1000,"output_tokens":9000}}}),
            ~s({"type":"assistant","timestamp":"2026-07-01T23:05:00.000Z","message":{"id":"msg-2","usage":{"input_tokens":7,"output_tokens":11}}})
          ],
          "\n"
        ) <> "\n"
      )

      assert {:ok, totals} =
               SessionFile.read_totals(path, since: ~U[2026-07-01 23:00:00.000000Z])

      assert totals.tokens_in == 7
      assert totals.tokens_out == 11
      assert totals.message_count == 1
    end

    test "an undated line is treated as out-of-window when a cutoff is given" do
      # Under-reporting beats billing this run for another run's tokens.
      dir = tmp_dir()
      path = Path.join(dir, "undated.jsonl")

      File.write!(
        path,
        ~s({"type":"assistant","message":{"id":"msg-x","usage":{"input_tokens":42,"output_tokens":7}}}) <>
          "\n"
      )

      assert {:ok, with_cutoff} =
               SessionFile.read_totals(path, since: ~U[2026-07-01 00:00:00.000000Z])

      assert with_cutoff.message_count == 0
      assert with_cutoff.skipped_before_since == 1

      # Without a cutoff nothing changes for undated files.
      assert {:ok, no_cutoff} = SessionFile.read_totals(path)
      assert no_cutoff.tokens_in == 42
    end

    test "usage_for/3 threads :since through to the reader" do
      dir = tmp_dir()
      _path = write_session!(dir, "/some/where", "sid-since")

      assert {:ok, totals} =
               SessionFile.usage_for(dir, "sid-since", since: ~U[2026-07-01 23:30:00.000000Z])

      assert totals.tokens_out == 200
      assert totals.message_count == 1
    end
  end

  describe "locate/2" do
    test "finds the session file by session id under config_dir/projects" do
      dir = tmp_dir()
      path = write_session!(dir, "/some/where", "abc-123")
      assert {:ok, ^path} = SessionFile.locate(dir, "abc-123")
    end

    test "returns :not_found when there is no matching session file" do
      assert :not_found = SessionFile.locate(tmp_dir(), "missing-sid")
    end
  end

  describe "usage_for/2" do
    test "locates and reads in one call" do
      dir = tmp_dir()
      _path = write_session!(dir, "/some/where", "sid-9")
      assert {:ok, totals} = SessionFile.usage_for(dir, "sid-9")
      assert totals.tokens_out == 300
    end

    test "returns :not_found for an unknown session" do
      assert :not_found = SessionFile.usage_for(tmp_dir(), "unknown")
    end
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "arb_sessionfile_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
