defmodule Arbiter.QuotaTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  @headers [
    {"anthropic-ratelimit-unified-5h-utilization", "0.24"},
    {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
    {"anthropic-ratelimit-unified-5h-status", "allowed"},
    {"anthropic-ratelimit-unified-7d-utilization", "0.08"},
    {"anthropic-ratelimit-unified-7d-reset", "1782748800"},
    {"anthropic-ratelimit-unified-7d-status", "allowed"},
    {"anthropic-ratelimit-unified-representative-claim", "five_hour"},
    {"anthropic-ratelimit-unified-overage-status", "rejected"},
    {"content-type", "application/json"}
  ]

  defp workspace!(name \\ "default") do
    Ash.create!(Workspace, %{name: name})
  end

  describe "parse_unified_headers/1" do
    test "extracts the unified rate-limit family, converting types" do
      attrs = Quota.parse_unified_headers(@headers)

      assert attrs.utilization_5h == 0.24
      assert attrs.status_5h == "allowed"
      assert attrs.utilization_7d == 0.08
      assert attrs.representative_claim == "five_hour"
      assert attrs.overage_status == "rejected"
      assert %DateTime{} = attrs.reset_5h_at
      assert DateTime.to_unix(attrs.reset_5h_at) == 1_782_247_200
      assert DateTime.to_unix(attrs.reset_7d_at) == 1_782_748_800
    end

    test "returns an empty map when no unified headers are present" do
      assert Quota.parse_unified_headers([{"content-type", "application/json"}]) == %{}
    end

    test "is case-insensitive on header names" do
      attrs =
        Quota.parse_unified_headers([
          {"ANTHROPIC-RateLimit-Unified-5h-Utilization", "0.5"}
        ])

      assert attrs.utilization_5h == 0.5
    end
  end

  describe "capture/3" do
    test "upserts a snapshot for the given workspace" do
      ws = workspace!()

      assert {:ok, quota} = Quota.capture(ws.id, @headers)
      assert quota.workspace_id == ws.id
      assert quota.provider == "claude"
      assert quota.utilization_5h == 0.24
      assert %DateTime{} = quota.captured_at
    end

    test "is a no-op when no unified headers are present" do
      ws = workspace!()
      assert Quota.capture(ws.id, [{"content-type", "application/json"}]) == :noop
    end

    test "overwrites the prior snapshot in place (one row per workspace)" do
      ws = workspace!()

      assert {:ok, _} = Quota.capture(ws.id, @headers)

      updated =
        List.keyreplace(
          @headers,
          "anthropic-ratelimit-unified-5h-utilization",
          0,
          {"anthropic-ratelimit-unified-5h-utilization", "0.99"}
        )

      assert {:ok, q2} = Quota.capture(ws.id, updated)
      assert q2.utilization_5h == 0.99

      assert Quota.latest(ws.id).utilization_5h == 0.99
    end

    test "falls back to the default workspace when none is given" do
      ws = workspace!()
      assert {:ok, quota} = Quota.capture(nil, @headers)
      assert quota.workspace_id == ws.id
    end
  end

  describe "serialize/2" do
    test "renders ISO-8601 timestamps and nil when absent" do
      ws = workspace!()
      assert Quota.serialize(ws.id) == nil

      {:ok, _} = Quota.capture(ws.id, @headers)
      serialized = Quota.serialize(ws.id)

      assert serialized.utilization_5h == 0.24
      assert is_binary(serialized.reset_5h_at)
      assert {:ok, _, _} = DateTime.from_iso8601(serialized.captured_at)
    end
  end

  describe "proxy config" do
    test "worker_base_url bakes in the workspace id" do
      Application.put_env(:arbiter, :anthropic_proxy,
        enabled: true,
        base_url: "http://127.0.0.1:4848/proxy/anthropic"
      )

      on_exit(fn ->
        Application.put_env(:arbiter, :anthropic_proxy,
          enabled: false,
          base_url: "http://127.0.0.1:4848/proxy/anthropic"
        )
      end)

      assert Quota.proxy_enabled?()
      assert Quota.worker_base_url("ws-123") == "http://127.0.0.1:4848/proxy/anthropic/ws-123"
      assert Quota.worker_base_url(nil) == "http://127.0.0.1:4848/proxy/anthropic"
    end
  end
end
