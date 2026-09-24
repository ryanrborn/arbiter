defmodule ArbiterWeb.Api.BreakerControllerTest do
  @moduledoc """
  The transport behind `arb breaker list` / `arb breaker reset` (bd-5jr49o) —
  acceptance 1 and 5.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.CircuitBreaker
  alias Arbiter.Tasks.Workspace

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    ws = Ash.create!(Workspace, %{name: "breaker-api-#{System.unique_integer([:positive])}"})
    {:ok, ws: ws}
  end

  defp trip(ws) do
    opts = [workspace_id: ws.id, limit: 1, window_ms: 60_000, escalate: false]
    CircuitBreaker.check(:coordinator_escalation, "runaway", opts)
    CircuitBreaker.check(:coordinator_escalation, "runaway", opts)
  end

  test "GET /api/breakers lists the call-site registry with no live breakers", %{conn: conn} do
    resp = conn |> get("/api/breakers") |> json_response(200)

    assert resp["breakers"] == []
    assert resp["open_count"] == 0

    kinds = Enum.map(resp["call_sites"], & &1["kind"])

    for kind <- ~w(pr_patrol_follow_up watchdog_merge_escalation preflight_auth_failed
                   dispatch_queue_redispatch coordinator_escalation) do
      assert kind in kinds
    end
  end

  test "GET /api/breakers reports a tripped breaker", %{conn: conn, ws: ws} do
    trip(ws)

    resp = conn |> get("/api/breakers", %{"workspace" => ws.id}) |> json_response(200)

    assert [entry] = resp["breakers"]
    assert entry["open"] == true
    assert entry["kind"] == "coordinator_escalation"
    assert entry["count"] == 2
    assert resp["open_count"] == 1
  end

  test "POST /api/breakers/reset closes one breaker by signature", %{conn: conn, ws: ws} do
    assert {:suppress, info} = trip(ws)

    resp =
      conn
      |> post("/api/breakers/reset", %{"signature" => info.signature})
      |> json_response(200)

    assert resp["reset"] == 1
    assert conn |> get("/api/breakers") |> json_response(200) |> Map.fetch!("breakers") == []
  end

  test "POST /api/breakers/reset with --all scoped to a workspace", %{conn: conn, ws: ws} do
    trip(ws)

    resp =
      conn
      |> post("/api/breakers/reset", %{"all" => true, "workspace" => ws.id})
      |> json_response(200)

    assert resp["reset"] == 1
  end

  test "POST /api/breakers/reset without a target is a 4xx, not a silent no-op", %{conn: conn} do
    assert conn |> post("/api/breakers/reset", %{}) |> json_response(400)
  end

  test "POST /api/breakers/reset on an unknown signature is a 4xx", %{conn: conn} do
    assert conn |> post("/api/breakers/reset", %{"signature" => "nope"}) |> json_response(400)
  end

  # A misspelled kind used to resolve to `nil`, which `maybe_put/3` then dropped
  # — so "re-arm this one kind" silently re-armed every breaker in the
  # workspace. The MCP tool rejects the same typo, so both surfaces must.
  test "POST /api/breakers/reset with an unknown kind errors instead of resetting everything",
       %{conn: conn, ws: ws} do
    trip(ws)

    resp =
      conn
      |> post("/api/breakers/reset", %{
        "all" => true,
        "workspace" => ws.id,
        "kind" => "pr_patrol_followup"
      })
      |> json_response(400)

    assert resp["error"]["type"] == "invalid_request"
    assert resp["error"]["message"] =~ "unknown breaker kind"

    # And the breaker the operator did not name is still open.
    assert conn
           |> get("/api/breakers", %{"workspace" => ws.id})
           |> json_response(200)
           |> Map.fetch!("open_count") == 1
  end

  test "GET /api/breakers with an unknown kind is a 4xx, not an unfiltered listing",
       %{conn: conn, ws: ws} do
    trip(ws)

    assert conn
           |> get("/api/breakers", %{"kind" => "coordinator_escalations"})
           |> json_response(400)
  end

  test "GET /api/breakers with a known kind still filters", %{conn: conn, ws: ws} do
    trip(ws)

    resp =
      conn
      |> get("/api/breakers", %{"workspace" => ws.id, "kind" => "coordinator_escalation"})
      |> json_response(200)

    assert [%{"kind" => "coordinator_escalation"}] = resp["breakers"]

    assert conn
           |> get("/api/breakers", %{"workspace" => ws.id, "kind" => "pr_patrol_follow_up"})
           |> json_response(200)
           |> Map.fetch!("breakers") == []
  end

  test "GET /api/breakers with an empty kind means no filter", %{conn: conn, ws: ws} do
    trip(ws)

    resp =
      conn |> get("/api/breakers", %{"workspace" => ws.id, "kind" => ""}) |> json_response(200)

    assert length(resp["breakers"]) == 1
  end

  describe "auth holds (bd-21bmdh)" do
    setup do
      {:ok, _} = Arbiter.Agents.AuthHold.reset(:all)
      Arbiter.Agents.CredentialWatchdog.reset()

      on_exit(fn ->
        {:ok, _} = Arbiter.Agents.AuthHold.reset(:all)
        Arbiter.Agents.CredentialWatchdog.reset()
      end)
    end

    defp open_codex_hold do
      reason = %Arbiter.Worker.StopReason{
        category: :auth_expired,
        summary: "401",
        remediation: nil,
        exit_status: 1,
        signal: nil
      }

      :counted = Arbiter.Agents.AuthHold.record_death(Arbiter.Agents.Codex, reason)
      :opened = Arbiter.Agents.AuthHold.record_death(Arbiter.Agents.Codex, reason)
    end

    test "GET /api/breakers lists the open hold", %{conn: conn} do
      open_codex_hold()

      assert [%{"provider" => "codex", "open" => true, "deaths" => 2}] =
               conn |> get("/api/breakers") |> json_response(200) |> Map.fetch!("auth_holds")
    end

    test "POST /api/breakers/reset with provider clears it", %{conn: conn} do
      open_codex_hold()

      resp = conn |> post("/api/breakers/reset", %{"provider" => "codex"}) |> json_response(200)

      assert resp["reset"] == 1
      assert resp["auth_hold"] == "codex"
      refute Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Codex)
    end

    test "POST /api/breakers/reset with an unknown provider is a 4xx", %{conn: conn} do
      assert conn |> post("/api/breakers/reset", %{"provider" => "nope"}) |> json_response(400)
    end
  end
end
