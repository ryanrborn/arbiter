defmodule Arbiter.Usage.CodexSessionFileTest do
  # Pure filesystem/parse module — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Arbiter.Usage.CodexSessionFile, as: SessionFile

  # Verbatim shape confirmed live against installed codex-cli 0.153.4 (bd-96mn8i
  # round 2, finding 1) — the exact envelope of
  # `~/.codex/sessions/2026/09/21/rollout-2026-09-21T12-23-15-01a0c4c7-….jsonl`:
  # a rollout opens with an unwrapped `session_meta` line, and every other
  # event (including `token_count`) is wrapped in
  # `{"type":"event_msg","payload":{...}}`.
  defp rollout_lines(session_id, timestamp, tokens_in, cached, tokens_out) do
    [
      ~s({"timestamp":"#{timestamp}","ordinal":0,"type":"session_meta",) <>
        ~s("payload":{"session_id":"#{session_id}","timestamp":"#{timestamp}"}}),
      ~s({"timestamp":"#{timestamp}","ordinal":1,"type":"event_msg",) <>
        ~s("payload":{"type":"turn_context","cwd":"/tmp"}}),
      ~s({"timestamp":"#{timestamp}","ordinal":2,"type":"event_msg",) <>
        ~s("payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":#{tokens_in},) <>
        ~s("cached_input_tokens":#{cached},"cache_write_input_tokens":0,) <>
        ~s("output_tokens":#{tokens_out},"reasoning_output_tokens":0}}}})
    ]
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
    lines = rollout_lines(session_id, timestamp, tokens_in, cached, tokens_out)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp pad(n, len), do: n |> Integer.to_string() |> String.pad_leading(len, "0")

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "codex-session-file-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # bd-96mn8i round 2, finding 1/AC3: exercised against a real, live rollout
  # on this host, not only the hand-built fixtures below. Skips (rather than
  # failing) on a host with no codex CLI history.
  describe "read_totals/1 against a real rollout" do
    @tag :live_codex
    test "reads real, non-zero tokens off an actual on-disk codex rollout" do
      case Path.wildcard(Path.join([SessionFile.sessions_dir(), "**", "*.jsonl"])) do
        [] ->
          :ok

        paths ->
          path = List.last(Enum.sort(paths))
          assert {:ok, totals} = SessionFile.read_totals(path)

          if totals.tokens_in do
            assert totals.tokens_in > 0
            assert is_integer(totals.tokens_out)
          end
      end
    end
  end

  describe "read_totals/1" do
    test "reads the token_count event's totals via Codex.Stream's own field mapping" do
      dir = tmp_dir()

      path =
        write_rollout!(
          dir,
          ~D[2026-09-17],
          "sid-1",
          "2026-09-17T00:04:32.619Z",
          18_915,
          18_176,
          5
        )

      assert {:ok, totals} = SessionFile.read_totals(path)
      assert totals.tokens_in == 18_915
      assert totals.tokens_out == 5
      assert totals.cache_read_tokens == 18_176
    end

    test "keeps the LAST token_count line when several appear (cumulative totals)" do
      dir = tmp_dir()

      lines =
        rollout_lines("sid-2", "2026-09-17T00:04:32.619Z", 100, 0, 1) ++
          rollout_lines("sid-2", "2026-09-17T00:04:33.000Z", 18_915, 18_176, 5)

      path = Path.join(dir, "multi.jsonl")
      File.write!(path, Enum.join(lines, "\n") <> "\n")

      assert {:ok, totals} = SessionFile.read_totals(path)
      assert totals.tokens_in == 18_915
      assert totals.tokens_out == 5
    end

    test "a rollout with no token_count line reads all-nil totals" do
      dir = tmp_dir()
      path = Path.join(dir, "no-usage.jsonl")

      File.write!(
        path,
        ~s({"type":"session_meta","payload":{"session_id":"s","timestamp":"2026-09-17T00:00:00Z"}}) <>
          "\n"
      )

      assert {:ok, totals} = SessionFile.read_totals(path)
      assert totals.tokens_in == nil
      assert totals.tokens_out == nil
    end

    test "missing file is an error, not a crash" do
      assert {:error, _} = SessionFile.read_totals(Path.join(tmp_dir(), "nope.jsonl"))
    end
  end

  describe "session_meta_timestamp/1" do
    test "parses the first line's timestamp" do
      dir = tmp_dir()
      path = write_rollout!(dir, ~D[2026-09-17], "sid-3", "2026-09-17T00:04:32.619Z", 1, 0, 1)

      assert %DateTime{} = ts = SessionFile.session_meta_timestamp(path)
      assert DateTime.to_iso8601(ts) == "2026-09-17T00:04:32.619Z"
    end

    test "a file whose first line isn't session_meta is :error" do
      dir = tmp_dir()
      path = Path.join(dir, "odd.jsonl")
      File.write!(path, ~s({"type":"turn_context"}) <> "\n")
      assert SessionFile.session_meta_timestamp(path) == :error
    end
  end

  describe "find_for_probe/4" do
    test "matches a row's estimated probe start to the closest rollout, within tolerance" do
      dir = tmp_dir()

      # Confirmed live match (bd-96mn8i round 2 review): DB row
      # occurred_at=2026-09-17T00:04:36.349Z, duration_ms=4505 (start ≈
      # 00:04:31.8Z) ↔ rollout session_meta.timestamp=2026-09-17T00:04:32.619Z.
      write_rollout!(dir, ~D[2026-09-17], "close", "2026-09-17T00:04:32.619Z", 18_915, 18_176, 5)
      write_rollout!(dir, ~D[2026-09-17], "far", "2026-09-17T04:00:00.000Z", 1, 1, 1)

      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      assert {:ok, path} = SessionFile.find_for_probe(occurred_at, 4505, 5_000, sessions_dir: dir)
      assert Path.basename(path) == "rollout-close.jsonl"
    end

    test "returns :not_found when nothing is within tolerance" do
      dir = tmp_dir()
      write_rollout!(dir, ~D[2026-09-17], "far", "2026-09-17T04:00:00.000Z", 1, 1, 1)

      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      assert SessionFile.find_for_probe(occurred_at, 4505, 5_000, sessions_dir: dir) == :not_found
    end

    test "returns :not_found on an empty sessions dir" do
      dir = tmp_dir()

      assert SessionFile.find_for_probe(DateTime.utc_now(), 100, 5_000, sessions_dir: dir) ==
               :not_found
    end

    test "a nil duration_ms falls back to occurred_at as the start estimate" do
      dir = tmp_dir()
      write_rollout!(dir, ~D[2026-09-17], "nodur", "2026-09-17T00:04:36.000Z", 1, 1, 1)

      occurred_at = ~U[2026-09-17 00:04:36.349Z]

      assert {:ok, path} = SessionFile.find_for_probe(occurred_at, nil, 5_000, sessions_dir: dir)
      assert Path.basename(path) == "rollout-nodur.jsonl"
    end
  end
end
