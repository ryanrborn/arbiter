defmodule Mix.Tasks.Arbiter.BackfillCodexUsageTest do
  # The task's boot path cannot run under the test sandbox (see
  # arbiter_archive_sessions_test.exs), so this asserts statically that it
  # starts only the Repo, not the full application: booting `Arbiter.Application`
  # next to a live coordinator would start a second endpoint, Autopilot and
  # patrol set against the same production database (bd-96mn8i round-8 ruling).
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.backfill_codex_usage.ex")
  # `run/1`'s body only — excludes the moduledoc, which quotes the forbidden
  # call by name to explain why it's absent.
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"
    assert @run_body =~ "start_repo!()", "must start only the Repo via start_repo!/0"
  end

  test "documents that it starts the Repo, not the application" do
    assert @source =~ "starts the Repo, not the application"
  end
end
