defmodule Mix.Tasks.Arbiter.BackfillTaskStatusesTest do
  # This task used to call Mix.Task.run("app.start"), booting a second full
  # Arbiter (endpoint, Autopilot, patrols) next to a live coordinator
  # (bd-64ye6w). It now delegates to Arbiter.Release.backfill/2, which starts
  # only Ash + the Repo.
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.backfill_task_statuses.ex")
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"

    assert @run_body =~ "Arbiter.Release.backfill(:task_statuses",
           "must delegate to the release-callable backfill"
  end

  test "documents the release eval invocation" do
    assert @source =~ "bin/arbiter eval"
    assert @source =~ "Arbiter.Release.backfill(:task_statuses"
  end
end
