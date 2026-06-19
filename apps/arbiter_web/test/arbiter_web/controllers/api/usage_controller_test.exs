defmodule ArbiterWeb.Api.UsageControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Usage.Event

  @ws "ws-api-usage"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_event!(attrs) do
    base = %{
      bead_id: "bd-#{System.unique_integer([:positive])}",
      repo: "arbiter",
      workspace_id: @ws,
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "GET /api/usage" do
    test "rolls up by bead", %{conn: conn} do
      _ = insert_event!(%{bead_id: "bd-r1", cost_usd: 1.0, tokens_in: 100})
      _ = insert_event!(%{bead_id: "bd-r1", cost_usd: 2.0, tokens_in: 200})
      _ = insert_event!(%{bead_id: "bd-r2", cost_usd: 0.5})

      conn = get(conn, ~p"/api/usage", %{by: "bead", workspace_id: @ws})
      body = json_response(conn, 200)
      assert body["by"] == "bead"

      data = Map.new(body["data"], &{&1["group"], &1})
      assert data["bd-r1"]["rows"] == 2
      assert_in_delta data["bd-r1"]["total_cost_usd"], 3.0, 0.001
      assert data["bd-r1"]["tokens_in"] == 300
      assert_in_delta data["bd-r2"]["total_cost_usd"], 0.5, 0.001
    end

    test "rolls up by day chronologically", %{conn: conn} do
      _ = insert_event!(%{cost_usd: 1.0, occurred_at: ~U[2026-06-01 10:00:00.000000Z]})
      _ = insert_event!(%{cost_usd: 0.5, occurred_at: ~U[2026-06-02 10:00:00.000000Z]})

      conn = get(conn, ~p"/api/usage", %{by: "day", workspace_id: @ws})
      groups = Enum.map(json_response(conn, 200)["data"], & &1["group"])
      assert groups == ["2026-06-01", "2026-06-02"]
    end

    test "by step splits work vs review", %{conn: conn} do
      _ = insert_event!(%{step: :work, cost_usd: 1.0})
      _ = insert_event!(%{step: :review, cost_usd: 0.5, bead_id: "bd-r#review"})

      conn = get(conn, ~p"/api/usage", %{by: "step", workspace_id: @ws})
      by_step = Map.new(json_response(conn, 200)["data"], &{&1["group"], &1})
      assert by_step["work"]["rows"] == 1
      assert by_step["review"]["rows"] == 1
    end

    test "missing by returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "invalid by returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{by: "galaxy"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "GET /api/usage/events" do
    test "returns raw event rows newest first", %{conn: conn} do
      now = DateTime.utc_now()

      _ =
        insert_event!(%{
          bead_id: "bd-e1",
          cost_usd: 0.1,
          occurred_at: DateTime.add(now, -20, :second)
        })

      _ = insert_event!(%{bead_id: "bd-e2", cost_usd: 0.2, occurred_at: now})

      conn = get(conn, ~p"/api/usage/events", %{workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      ids = Enum.map(data, & &1["bead_id"])
      assert hd(ids) == "bd-e2"
    end

    test "bead_id filter", %{conn: conn} do
      _ = insert_event!(%{bead_id: "bd-only", cost_usd: 0.3})
      _ = insert_event!(%{bead_id: "bd-other", cost_usd: 0.4})

      conn = get(conn, ~p"/api/usage/events", %{bead_id: "bd-only", workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      assert Enum.all?(data, &(&1["bead_id"] == "bd-only"))
    end

    test "bead_id filter includes review_gate reviewer events (#review suffix)", %{conn: conn} do
      _ = insert_event!(%{bead_id: "bd-trib", step: :work, cost_usd: 0.1})
      _ = insert_event!(%{bead_id: "bd-trib#review", step: :review, cost_usd: 0.2})
      _ = insert_event!(%{bead_id: "bd-trib#review#r2", step: :review, cost_usd: 0.3})
      _ = insert_event!(%{bead_id: "bd-unrelated", cost_usd: 0.9})

      conn = get(conn, ~p"/api/usage/events", %{bead_id: "bd-trib", workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      returned_ids = Enum.map(data, & &1["bead_id"]) |> Enum.sort()
      assert returned_ids == ["bd-trib", "bd-trib#review", "bd-trib#review#r2"]
    end

    test "bead_id filter with --step review returns only reviewer events", %{conn: conn} do
      _ = insert_event!(%{bead_id: "bd-trib2", step: :work, cost_usd: 0.1})
      _ = insert_event!(%{bead_id: "bd-trib2#review", step: :review, cost_usd: 0.2})

      conn =
        get(conn, ~p"/api/usage/events", %{bead_id: "bd-trib2", step: "review", workspace_id: @ws})

      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["bead_id"] == "bd-trib2#review"
      assert hd(data)["step"] == "review"
    end
  end
end
