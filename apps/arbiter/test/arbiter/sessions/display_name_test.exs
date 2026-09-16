defmodule Arbiter.Sessions.DisplayNameTest do
  @moduledoc """
  The display-name ladder (bd-o2vtsz): operator name → latest `ai-title` →
  short id, resolved in one place both the sessions list and any future
  surface (the session dock) can call.

  No DB and no real provisioning needed — `Session` is a plain struct and
  everything here is either pure or reads a JSONL fixture from a tmp dir, so
  this is a fast unit test rather than an integration one.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.DisplayName
  alias Arbiter.Sessions.Session

  @id "0197abcd-1111-7000-8000-000000000001"

  defp tmp_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bd-o2vtsz-displayname-#{tag}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Same layout `Arbiter.Usage.ClaudeSessionFile.locate/2` globs:
  # `<config_dir>/projects/<slug>/<session_id>.jsonl`.
  defp write_transcript!(config_dir, session_id, lines) do
    dir = Path.join([config_dir, "projects", "some-slug"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, session_id <> ".jsonl"), Enum.join(lines, "\n") <> "\n")
  end

  defp session(attrs) do
    struct(
      Session,
      Map.merge(%{id: @id, name: nil, config_dir: nil, provider_session_id: nil}, attrs)
    )
  end

  describe "resolve/1 — the ladder" do
    test "rung 1: an operator name wins even when an ai-title exists" do
      config_dir = tmp_dir!("rung1")

      write_transcript!(config_dir, "sid-1", [
        ~s({"type":"ai-title","aiTitle":"Epic detail aggregation","sessionId":"sid-1"})
      ])

      s = session(%{name: "my session", config_dir: config_dir, provider_session_id: "sid-1"})
      assert DisplayName.resolve(s) == "my session"
    end

    test "a blank operator name does not count as one" do
      config_dir = tmp_dir!("rung1-blank")

      write_transcript!(config_dir, "sid-1", [
        ~s({"type":"ai-title","aiTitle":"Epic detail aggregation","sessionId":"sid-1"})
      ])

      s = session(%{name: "   ", config_dir: config_dir, provider_session_id: "sid-1"})
      assert DisplayName.resolve(s) == "Epic detail aggregation"
    end

    test "rung 2: no operator name → the latest ai-title" do
      config_dir = tmp_dir!("rung2")

      write_transcript!(config_dir, "sid-2", [
        ~s({"type":"ai-title","aiTitle":"First guess","sessionId":"sid-2"}),
        ~s({"type":"assistant","sessionId":"sid-2"}),
        ~s({"type":"ai-title","aiTitle":"Better title","sessionId":"sid-2"})
      ])

      s = session(%{config_dir: config_dir, provider_session_id: "sid-2"})
      assert DisplayName.resolve(s) == "Better title"
    end

    test "rung 3: no name and no ai-title yet (pre-first-title) → short id" do
      s = session(%{provider_session_id: nil})
      assert DisplayName.resolve(s) == "0197abcd"
    end

    test "rung 3: no name, and no transcript at all (config_dir unset) → short id" do
      s = session(%{provider_session_id: "sid-3"})
      assert DisplayName.resolve(s) == "0197abcd"
    end
  end

  describe "ai_title/1 — best-effort reading" do
    test "degrades to nil when config_dir does not exist on disk" do
      s = session(%{config_dir: "/does/not/exist", provider_session_id: "sid-4"})
      assert DisplayName.ai_title(s) == nil
    end

    test "degrades to nil when the transcript has no ai-title record yet" do
      config_dir = tmp_dir!("no-title")
      write_transcript!(config_dir, "sid-5", [~s({"type":"assistant","sessionId":"sid-5"})])

      s = session(%{config_dir: config_dir, provider_session_id: "sid-5"})
      assert DisplayName.ai_title(s) == nil
    end

    test "skips a malformed or truncated line rather than crashing" do
      config_dir = tmp_dir!("malformed")

      write_transcript!(config_dir, "sid-6", [
        ~s({"type":"ai-title","aiTitle":"Good title","sessionId":"sid-6"}),
        ~s({"type":"ai-title","aiTitle":"broken json,"sessionId"),
        ~s({not even json at all)
      ])

      s = session(%{config_dir: config_dir, provider_session_id: "sid-6"})
      assert DisplayName.ai_title(s) == "Good title"
    end

    test "never surfaces Claude Code's cwd-derived name from sessions/<pid>.json" do
      config_dir = tmp_dir!("derived-name")

      sessions_dir = Path.join(config_dir, "sessions")
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "12345.json"),
        Jason.encode!(%{
          "pid" => 12_345,
          "sessionId" => "sid-7",
          "cwd" => "/home/ryan/dev/arbiter-worktrees/foo/workspace",
          "name" => "workspace-a2",
          "nameSource" => "derived"
        })
      )

      s = session(%{config_dir: config_dir, provider_session_id: "sid-7"})

      refute DisplayName.ai_title(s) == "workspace-a2"
      refute DisplayName.resolve(s) == "workspace-a2"
      assert DisplayName.resolve(s) == "0197abcd"
    end
  end

  describe "short_id/1" do
    test "the first UUID segment" do
      assert DisplayName.short_id("0197abcd-1111-7000-8000-000000000001") == "0197abcd"
    end
  end
end
