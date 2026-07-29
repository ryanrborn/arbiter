defmodule Arbiter.Loop.CorpusTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Corpus

  describe "record_pass_cost/1 — the pass's single ledger write" do
    test "inserts one usage_events row for the pass itself (step :other)" do
      before = count_events()

      id =
        Corpus.record_pass_cost(%{duration_ms: 1234, rows_scanned: 42, workspace_id: nil})

      assert is_binary(id)
      assert count_events() == before + 1

      %{rows: [[task_id, step, model]]} =
        Repo.query!(
          "SELECT task_id, step, model FROM usage_events WHERE id = ?1",
          [id]
        )

      assert task_id == "loop-analyze"
      assert step == "other"
      assert model == "loop-analysis-pass"
    end
  end

  describe "fetch/1 — bounded window read" do
    test "an empty window yields no rows and a well-formed meta" do
      since = ~U[2000-01-01 00:00:00Z]
      until = ~U[2000-01-08 00:00:00Z]

      assert {:ok, [], meta} = Corpus.fetch(since: since, until: until, label: "ancient")
      assert meta.label == "ancient"
      assert meta.since == since
      assert meta.until == until
    end
  end

  defp count_events do
    %{rows: [[n]]} = Repo.query!("SELECT COUNT(*) FROM usage_events", [])
    n
  end
end
