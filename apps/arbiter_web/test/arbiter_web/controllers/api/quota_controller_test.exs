defmodule ArbiterWeb.Api.QuotaControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  setup do
    ws = Ash.create!(Workspace, %{name: "default"})
    {:ok, ws: ws}
  end

  test "returns null claude quota before capture (default workspace)", %{conn: conn, ws: ws} do
    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["workspace_id"] == ws.id
    assert resp["data"]["claude"] == nil
  end

  test "carries gemini/antigravity keys, null when the fetch is disabled in test",
       %{conn: conn} do
    resp = conn |> get("/api/quota") |> json_response(200)
    # The Cloud Code Assist fetch is off in the test env, so these are always
    # present (never a missing key) but null — no live network call is made.
    assert Map.has_key?(resp["data"], "gemini")
    assert Map.has_key?(resp["data"], "antigravity")
    assert resp["data"]["gemini"] == nil
    assert resp["data"]["antigravity"] == nil
  end

  test "returns the captured snapshot for the default workspace", %{conn: conn, ws: ws} do
    {:ok, _} =
      Quota.capture(ws.id, [
        {"anthropic-ratelimit-unified-5h-utilization", "0.24"},
        {"anthropic-ratelimit-unified-5h-status", "allowed"},
        {"anthropic-ratelimit-unified-representative-claim", "five_hour"}
      ])

    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["claude"]["utilization_5h"] == 0.24
    assert resp["data"]["claude"]["status_5h"] == "allowed"
  end

  test "resolves an explicit ?workspace= by id", %{conn: conn} do
    other = Ash.create!(Workspace, %{name: "by-id"})
    {:ok, _} = Quota.capture(other.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.6"}])

    resp = conn |> get("/api/quota?workspace=#{other.id}") |> json_response(200)
    assert resp["data"]["workspace_id"] == other.id
    assert resp["data"]["claude"]["utilization_5h"] == 0.6
  end

  test "resolves an explicit ?workspace= by name", %{conn: conn} do
    other = Ash.create!(Workspace, %{name: "other"})

    {:ok, _} =
      Quota.capture(other.id, [
        {"anthropic-ratelimit-unified-7d-utilization", "0.5"}
      ])

    resp = conn |> get("/api/quota?workspace=other") |> json_response(200)
    assert resp["data"]["workspace_id"] == other.id
    assert resp["data"]["claude"]["utilization_7d"] == 0.5
  end

  test "404s an unknown workspace", %{conn: conn} do
    # need >1 workspace so a missing ref isn't silently the default
    Ash.create!(Workspace, %{name: "second"})
    resp = conn |> get("/api/quota?workspace=does-not-exist") |> json_response(404)
    assert resp["error"]["type"] == "not_found"
  end

  test "includes a quotas list alongside the legacy claude key", %{conn: conn, ws: ws} do
    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    resp = conn |> get("/api/quota") |> json_response(200)
    assert [%{"provider" => "claude", "utilization_5h" => 0.24}] = resp["data"]["quotas"]
  end

  test "the quotas list carries every tracked provider", %{conn: conn, ws: ws} do
    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "codex"
      )

    resp = conn |> get("/api/quota") |> json_response(200)
    providers = resp["data"]["quotas"] |> Enum.map(& &1["provider"]) |> Enum.sort()
    assert providers == ["claude", "codex"]
  end
end
