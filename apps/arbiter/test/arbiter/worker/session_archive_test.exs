defmodule Arbiter.Worker.SessionArchiveTest do
  # async: false — we swap the :output_log_root application env per test.
  use ExUnit.Case, async: false

  alias Arbiter.Worker.SessionArchive

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)

    root =
      Path.join(System.tmp_dir!(), "session-archive-test-#{System.unique_integer([:positive])}")

    Application.put_env(:arbiter, :output_log_root, root)

    cfg =
      Path.join(System.tmp_dir!(), "session-archive-cfg-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(cfg)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{root: root, config_dir: cfg, run_id: "run-#{System.unique_integer([:positive])}"}
  end

  # Build a fake Claude Code config dir holding one session JSONL (and,
  # optionally, subagent transcripts) exactly where `ClaudeSessionFile.locate/2`
  # globs for it.
  defp seed_session(cfg, session_id, lines, subagents \\ []) do
    slug = "-home-ryan-dev-arbiter"
    dir = Path.join([cfg, "projects", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, session_id <> ".jsonl")
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")

    Enum.each(subagents, fn {name, body} ->
      sub_dir = Path.join([dir, session_id, "subagents"])
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(sub_dir, name), body)
    end)

    path
  end

  defp gunzip_at!(path), do: path |> File.read!() |> :zlib.gunzip()

  describe "path_for/1" do
    test "lives in the durable log root, keyed by run id", %{root: root, run_id: run_id} do
      assert SessionArchive.path_for(run_id) == Path.join(root, run_id <> ".jsonl.gz")
    end

    test "subagent archives hang off a run-keyed directory", %{root: root, run_id: run_id} do
      assert SessionArchive.subagents_dir_for(run_id) ==
               Path.join(root, run_id <> ".subagents")
    end
  end

  describe "archive/3" do
    test "gzips the agent's session JSONL into the log root", ctx do
      sid = "11111111-1111-1111-1111-111111111111"
      lines = [%{"type" => "assistant", "message" => %{"id" => "m1"}}]
      seed_session(ctx.config_dir, sid, lines)

      assert {:ok, report} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)
      assert report.status == :ok
      assert report.subagents == 0

      archive = SessionArchive.path_for(ctx.run_id)
      assert File.regular?(archive)
      assert gunzip_at!(archive) =~ ~s("type":"assistant")
    end

    test "redacts known secret values before the bytes reach disk", ctx do
      sid = "22222222-2222-2222-2222-222222222222"
      secret = "sk-live-DEADBEEFCAFE"
      lines = [%{"type" => "user", "message" => %{"content" => "export KEY=#{secret}"}}]
      seed_session(ctx.config_dir, sid, lines)

      assert {:ok, _} =
               SessionArchive.archive(ctx.run_id, ctx.config_dir, sid, redact_values: [secret])

      body = gunzip_at!(SessionArchive.path_for(ctx.run_id))
      refute body =~ secret
      assert body =~ "[REDACTED]"
      # Redaction must not corrupt the JSONL: every line still parses.
      assert [%{"type" => "user"}] =
               body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end

    test "the archive is written 0600 — the root is secret-bearing", ctx do
      sid = "33333333-3333-3333-3333-333333333333"
      seed_session(ctx.config_dir, sid, [%{"type" => "assistant"}])

      assert {:ok, _} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)

      %File.Stat{mode: mode} = File.stat!(SessionArchive.path_for(ctx.run_id))
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "archives subagent transcripts under the parent run", ctx do
      sid = "44444444-4444-4444-4444-444444444444"

      seed_session(ctx.config_dir, sid, [%{"type" => "assistant"}], [
        {"agent-aad6d0303db231aef.jsonl", ~s({"type":"assistant","sub":true}\n)},
        {"agent-aad6d0303db231aef.meta.json", ~s({"name":"Explore"})}
      ])

      assert {:ok, report} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)
      assert report.subagents == 1

      sub =
        Path.join(
          SessionArchive.subagents_dir_for(ctx.run_id),
          "agent-aad6d0303db231aef.jsonl.gz"
        )

      assert File.regular?(sub)
      assert gunzip_at!(sub) =~ ~s("sub":true)
    end

    test "a run with no locatable session file reports :no_session_file, not an error", ctx do
      assert {:ok, %{status: :no_session_file}} =
               SessionArchive.archive(ctx.run_id, ctx.config_dir, "no-such-session")

      refute File.exists?(SessionArchive.path_for(ctx.run_id))
    end

    test "a non-Claude run (blank config_dir) reports :no_config_dir", ctx do
      assert {:ok, %{status: :no_config_dir}} = SessionArchive.archive(ctx.run_id, "", "sid")
      assert {:ok, %{status: :no_config_dir}} = SessionArchive.archive(ctx.run_id, nil, "sid")
    end

    test "re-archiving overwrites rather than appending (idempotent)", ctx do
      sid = "55555555-5555-5555-5555-555555555555"
      seed_session(ctx.config_dir, sid, [%{"type" => "assistant", "n" => 1}])
      assert {:ok, _} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)

      seed_session(ctx.config_dir, sid, [%{"type" => "assistant", "n" => 2}])
      assert {:ok, _} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)

      body = gunzip_at!(SessionArchive.path_for(ctx.run_id))
      assert body =~ ~s("n":2)
      refute body =~ ~s("n":1)
    end
  end

  describe "archived?/1 and read/1" do
    test "archived?/1 reports presence; read/1 returns the decompressed bytes", ctx do
      sid = "66666666-6666-6666-6666-666666666666"
      refute SessionArchive.archived?(ctx.run_id)

      seed_session(ctx.config_dir, sid, [%{"type" => "assistant", "hello" => "world"}])
      assert {:ok, _} = SessionArchive.archive(ctx.run_id, ctx.config_dir, sid)

      assert SessionArchive.archived?(ctx.run_id)
      assert {:ok, body} = SessionArchive.read(ctx.run_id)
      assert body =~ ~s("hello":"world")
    end

    test "read/1 on a run with no archive is {:error, :enoent}", ctx do
      assert {:error, :enoent} = SessionArchive.read(ctx.run_id)
    end
  end

  describe "archive_run/2" do
    test "reads config_dir / session_id off a run struct", ctx do
      sid = "77777777-7777-7777-7777-777777777777"
      seed_session(ctx.config_dir, sid, [%{"type" => "assistant", "via" => "run"}])

      run = %{id: ctx.run_id, config_dir: ctx.config_dir, session_id: sid, task_id: nil}

      assert {:ok, %{status: :ok}} = SessionArchive.archive_run(run, redact_values: [])
      assert gunzip_at!(SessionArchive.path_for(ctx.run_id)) =~ ~s("via":"run")
    end

    test "a Gemini run (session_id but no config_dir) is :no_config_dir, not a loss", ctx do
      run = %{
        id: ctx.run_id,
        config_dir: nil,
        session_id: "3ab7e7ea-8b87-4537-a271-840980e60907",
        task_id: nil
      }

      assert {:ok, %{status: :no_config_dir}} = SessionArchive.archive_run(run, redact_values: [])
      refute SessionArchive.archived?(ctx.run_id)
    end
  end
end
