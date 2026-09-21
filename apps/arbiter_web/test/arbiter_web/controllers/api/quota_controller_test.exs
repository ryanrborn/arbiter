defmodule ArbiterWeb.Api.QuotaControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  setup do
    ws = Ash.create!(Workspace, %{name: "default"})
    {:ok, ws: ws}
  end

  defp account_id!(ws_id, provider \\ "claude") do
    {:ok, id} = Quota.ensure_account_id(ws_id, provider)
    id
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

  test "includes a graceful codex no-op when Codex is not authenticated", %{conn: conn} do
    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["codex"] == nil
    assert is_binary(resp["data"]["codex_message"])
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

  # bd-1tuxv8: the gate reads both windows, so the API has to say which one is
  # holding dispatch — `arb quota` renders this line straight from here.
  test "reports the 7d window as the one gating dispatch", %{conn: conn, ws: ws} do
    {:ok, _} =
      Quota.capture(ws.id, [
        {"anthropic-ratelimit-unified-5h-utilization", "0.23"},
        {"anthropic-ratelimit-unified-5h-status", "allowed"},
        {"anthropic-ratelimit-unified-5h-reset", reset_epoch(3600)},
        {"anthropic-ratelimit-unified-7d-utilization", "0.91"},
        {"anthropic-ratelimit-unified-7d-status", "allowed"},
        {"anthropic-ratelimit-unified-representative-claim", "seven_day"}
      ])

    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["claude"]["gating_window"] == "7d"
    assert resp["data"]["claude"]["gating_reason"] == "7d quota 0.91 ≥ 0.90"
  end

  test "reports no gating window when both windows have headroom", %{conn: conn, ws: ws} do
    {:ok, _} =
      Quota.capture(ws.id, [
        {"anthropic-ratelimit-unified-5h-utilization", "0.23"},
        {"anthropic-ratelimit-unified-5h-status", "allowed"},
        {"anthropic-ratelimit-unified-5h-reset", reset_epoch(3600)},
        {"anthropic-ratelimit-unified-7d-utilization", "0.76"},
        {"anthropic-ratelimit-unified-7d-status", "allowed_warning"}
      ])

    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["claude"]["gating_window"] == nil
    assert resp["data"]["claude"]["gating_reason"] == nil
  end

  defp reset_epoch(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.to_unix()
    |> to_string()
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

  test "surfaces a persisted Gemini CLI snapshot from the DB (bd-ajh7bd)", %{conn: conn, ws: ws} do
    # The controller is now a pure DB read — no live Google fetch. A row
    # persisted by the CloudProbe (or here directly) is what surfaces.
    Ash.create!(Arbiter.Quota.GoogleQuota, %{
      provider_account_id: account_id!(ws.id, "gemini_cli"),
      provider: "gemini_cli",
      plan: "Free",
      used_percent: 75.0,
      snapshot: %{"provider" => "gemini-cli", "plan" => "Free", "models" => []},
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    resp = conn |> get("/api/quota") |> json_response(200)
    assert resp["data"]["gemini"]["plan"] == "Free"
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
  describe "P5: keyed by provider account (docs/provider-account-design.md §6)" do
    test "three workspaces on one account report one account row, not three", %{conn: conn, ws: ws} do
      account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "personal-max"})

      others =
        for name <- ["emricare", "vstim"], do: Ash.create!(Workspace, %{name: name})

      for w <- [ws | others] do
        Ash.create!(WorkspaceProviderAccount, %{
          workspace_id: w.id,
          provider: :claude,
          provider_account_id: account.id
        })

        {:ok, _} = Quota.capture(w.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])
      end

      assert [row] = Ash.read!(Arbiter.Quota.AnthropicQuota)
      assert row.provider_account_id == account.id

      for w <- [ws | others] do
        resp = conn |> get("/api/quota?workspace=#{w.id}") |> json_response(200)

        assert [quota] = resp["data"]["quotas"]
        assert quota["account"]["slug"] == "personal-max"
        assert quota["account"]["provider"] == "claude"

        assert Enum.map(quota["workspaces"], & &1["name"]) ==
                 ["default", "emricare", "vstim"]
      end
    end

    test "--json keeps workspace_id as a deprecated alias alongside account/workspaces",
         %{conn: conn, ws: ws} do
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      resp = conn |> get("/api/quota") |> json_response(200)

      assert resp["data"]["workspace_id"] == ws.id
      assert resp["data"]["workspace"]["name"] == "default"
      assert resp["data"]["account"]["provider"] == "claude"
      assert [%{"id" => id}] = resp["data"]["workspaces"]
      assert id == ws.id
      assert resp["data"]["claude"]["provider_account_id"] == account_id!(ws.id)
    end
  end
end
