defmodule ArbiterWeb.Api.ReviewGateRoundControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.ReviewGate.Round

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_round!(attrs) do
    base = %{
      task_id: "bd-rest-#{System.unique_integer([:positive])}",
      round: 1,
      role: :review
    }

    {:ok, round} = Ash.create(Round, Map.merge(base, attrs))
    round
  end

  describe "GET /api/review_gate_rounds" do
    test "returns rounds for a task, oldest-first", %{conn: conn} do
      task_id = "bd-rest-flow-#{System.unique_integer([:positive])}"

      insert_round!(%{
        task_id: task_id,
        round: 1,
        verdict: :request_changes,
        findings: "VERDICT: REQUEST_CHANGES\n1. fix it",
        finding_count: 1,
        reviewer_model: "claude-sonnet-5",
        cost_usd: 0.1,
        converged: false
      })

      insert_round!(%{
        task_id: task_id,
        round: 2,
        verdict: :approve,
        findings: "VERDICT: APPROVE",
        finding_count: 0,
        reviewer_model: "claude-sonnet-5",
        cost_usd: 0.2,
        converged: true
      })

      conn = get(conn, ~p"/api/review_gate_rounds", %{task_id: task_id})
      assert conn.status == 200

      {:ok, parsed} = Jason.decode(conn.resp_body)
      [r1, r2] = parsed["data"]

      assert r1["round"] == 1
      assert r1["verdict"] == "request_changes"
      assert r1["converged"] == false
      assert r2["round"] == 2
      assert r2["verdict"] == "approve"
      assert r2["converged"] == true
      assert r2["reviewer_model"] == "claude-sonnet-5"
      assert r2["cost_usd"] == 0.2
    end

    test "requires task_id", %{conn: conn} do
      conn = get(conn, ~p"/api/review_gate_rounds")
      assert conn.status == 400
    end
  end
end
