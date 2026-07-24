defmodule Arbiter.Usage.ClaudeSessionFileTest do
  # Pure filesystem/parse module — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Arbiter.Usage.ClaudeSessionFile, as: SessionFile

  # A hand-built session JSONL with the streaming-duplication the spike found:
  # two consecutive `assistant` lines share message.id "msg-1" with identical
  # usage (a re-emitted streaming snapshot, NOT incremental), so a naive sum
  # double-counts. The deduped (keep-first, by message.id) totals are:
  #   input=15  output=300  cache_read=3000  cache_creation=110  (2 messages)
  @lines [
    ~s({"type":"system","subtype":"init","session_id":"SID","model":"claude-opus-4-8"}),
    ~s({"type":"user","message":{"role":"user","content":"hi"}}),
    ~s({"type":"assistant","requestId":"req-1","uuid":"u-1a","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
    ~s({"type":"assistant","requestId":"req-1","uuid":"u-1b","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
    ~s(),
    ~s({"type":"assistant","requestId":"req-2","uuid":"u-2","message":{"id":"msg-2","model":"claude-opus-4-8","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":2000,"cache_creation_input_tokens":60}}}),
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
