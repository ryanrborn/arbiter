defmodule Mix.Tasks.Arbiter.BackfillGeminiUsageNoteTest do
  # Same reasoning as arbiter_backfill_codex_usage_test.exs: static assertion
  # that this task starts only the Repo, not the full application
  # (bd-96mn8i round-8 ruling).
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.backfill_gemini_usage_note.ex")
  # `run/1`'s body only — excludes the moduledoc, which quotes the forbidden
  # call by name to explain why it's absent.
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"

    assert @run_body =~ "Arbiter.Release.backfill(:gemini_usage_note",
           "must delegate to the release-callable backfill"
  end

  test "documents the release eval invocation" do
    assert @source =~ "bin/arbiter eval"
    assert @source =~ "Arbiter.Release.backfill(:gemini_usage_note"
  end
end
