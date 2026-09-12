defmodule Mix.Tasks.Arbiter.ArchiveSessionsTest do
  # The task's boot path (`Mix.Task.run("app.start")`) cannot run under the test
  # sandbox, so what is covered here is everything around it: the window
  # validation that deliberately happens *before* the app starts, and the
  # human-readable report — the only part of the sweep an operator reads.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbiter.ArchiveSessions

  defp empty_report do
    %{
      scanned: 0,
      archived: 0,
      already_archived: 0,
      no_config_dir: 0,
      no_session_id: 0,
      no_session_file: 0,
      too_large: 0,
      error: 0,
      bytes_in: 0,
      bytes_out: 0,
      subagents: 0,
      apply?: false
    }
  end

  test "report/2 states the compression actually achieved" do
    text =
      empty_report()
      |> Map.merge(%{scanned: 3, archived: 3, bytes_in: 10_485_760, bytes_out: 2_097_152})
      |> ArchiveSessions.report(true)

    assert text =~ "runs archived:"
    assert text =~ "10.0 MB"
    assert text =~ "2.0 MB"
    assert text =~ "5.0:1"
  end

  test "report/2 distinguishes a real loss from a run that never had a JSONL" do
    text =
      empty_report()
      |> Map.merge(%{scanned: 40, no_session_file: 12, no_config_dir: 5, no_session_id: 23})
      |> ArchiveSessions.report(false)

    # A pruned file is gone for good; the operator must not read that as a bug.
    assert text =~ ~r/no session file:\s+12\s+\(pruned by the CLI — irrecoverable\)/
    # A non-Claude run never had one — not a loss at all.
    assert text =~ ~r/no config dir:\s+5\s+\(non-Claude run — nothing was lost\)/
    assert text =~ ~r/no session id:\s+23/
  end

  test "report/2 does not claim to have written anything on a dry run" do
    assert ArchiveSessions.report(empty_report(), false) =~ "runs would archive:"
    refute ArchiveSessions.report(empty_report(), false) =~ "runs archived:"
    assert ArchiveSessions.report(empty_report(), true) =~ "runs archived:"
  end

  test "an unparseable window is rejected before the app boots" do
    assert_raise Mix.Error, ~r/--since must be an ISO8601 date/, fn ->
      ArchiveSessions.run(["--since", "not-a-date"])
    end

    assert_raise Mix.Error, ~r/--until must be an ISO8601 date/, fn ->
      ArchiveSessions.run(["--until", "2026-13-45"])
    end
  end
end
