defmodule Arbiter.ReviewGate.RoundTest do
  use Arbiter.DataCase, async: true

  require Ash.Query
  alias Arbiter.ReviewGate.Round

  defp create!(attrs) do
    base = %{
      task_id: "bd-#{System.unique_integer([:positive])}",
      round: 1,
      role: :review
    }

    {:ok, round} = Ash.create(Round, Map.merge(base, attrs))
    round
  end

  test "persists a reviewer round with a verdict and findings" do
    round =
      create!(%{
        verdict: :approve,
        findings: "VERDICT: APPROVE\nlooks good",
        finding_count: 0,
        reviewer_model: "claude-sonnet-5",
        cost_usd: 0.42,
        converged: true
      })

    assert round.role == :review
    assert round.verdict == :approve
    assert round.converged == true
    assert round.reviewer_model == "claude-sonnet-5"
    assert round.cost_usd == 0.42
    assert %DateTime{} = round.inserted_at
  end

  test "persists an implementer round with no verdict" do
    round =
      create!(%{
        role: :impl,
        findings: "addressed the findings by renaming the field",
        converged: false
      })

    assert round.role == :impl
    assert round.verdict == nil
    assert round.finding_count == nil
  end

  test "a rejected round 1 and an approved round 2 are two distinct rows" do
    task_id = "bd-round-flow-#{System.unique_integer([:positive])}"

    rejected =
      create!(%{
        task_id: task_id,
        round: 1,
        verdict: :request_changes,
        findings: "VERDICT: REQUEST_CHANGES\n1. fix the off-by-one",
        finding_count: 1,
        converged: false
      })

    approved =
      create!(%{
        task_id: task_id,
        round: 2,
        verdict: :approve,
        findings: "VERDICT: APPROVE",
        finding_count: 0,
        converged: true
      })

    rows =
      Round
      |> Ash.Query.filter(task_id == ^task_id)
      |> Ash.Query.sort(round: :asc)
      |> Ash.read!()

    assert [r1, r2] = rows
    assert r1.id == rejected.id
    assert r2.id == approved.id
    assert r1.verdict == :request_changes
    assert r2.verdict == :approve
    assert r1.converged == false
    assert r2.converged == true
  end

  test "rejects an invalid role" do
    assert {:error, _} =
             Ash.create(Round, %{task_id: "bd-bad-role", round: 1, role: :bogus})
  end
end
