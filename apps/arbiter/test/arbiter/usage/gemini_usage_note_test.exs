defmodule Arbiter.Usage.GeminiUsageNoteTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Usage.Event
  alias Arbiter.Usage.GeminiUsageNote

  defp create_event!(attrs) do
    base = %{
      provider: "gemini",
      source: :preflight,
      step: :other,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "backfill/1" do
    test "dry-run reports what it would note and does not touch the row" do
      ev =
        create_event!(%{
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (CLI returned no `--output-format json` result object)"
        })

      report = GeminiUsageNote.backfill()

      assert report.scanned == 1
      assert report.would_note == 1
      assert report.noted == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.cost_note =~ "CLI returned no `--output-format json` result object"
    end

    test "--apply rewrites the cost_note without touching token columns" do
      ev =
        create_event!(%{
          tokens_in: nil,
          tokens_out: nil,
          cost_note:
            "no structured usage in probe output (CLI returned no `--output-format json` result object)"
        })

      report = GeminiUsageNote.backfill(apply?: true)

      assert report.scanned == 1
      assert report.noted == 1

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
      assert reloaded.tokens_out == nil
      assert reloaded.cost_note =~ "unrecoverable"
      refute reloaded.cost_note =~ "--output-format json"
    end

    test "a row already carrying tokens is never touched" do
      ev = create_event!(%{tokens_in: 100, tokens_out: 20})

      report = GeminiUsageNote.backfill(apply?: true)
      assert report.scanned == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == 100
    end

    test "a source: :task gemini row is never scanned, even with nil tokens" do
      ev =
        create_event!(%{
          source: :task,
          task_id: Ash.UUID.generate(),
          tokens_in: nil,
          tokens_out: nil,
          cost_note: "a terminal event was observed, but it reported no usage payload"
        })

      report = GeminiUsageNote.backfill(apply?: true)
      assert report.scanned == 0

      reloaded = Ash.get!(Event, ev.id)

      assert reloaded.cost_note ==
               "a terminal event was observed, but it reported no usage payload"
    end

    test "a codex row is never scanned, even preflight with nil tokens" do
      ev =
        create_event!(%{
          provider: "codex",
          tokens_in: nil,
          tokens_out: nil
        })

      report = GeminiUsageNote.backfill(apply?: true)
      assert report.scanned == 0

      reloaded = Ash.get!(Event, ev.id)
      assert reloaded.tokens_in == nil
    end
  end
end
