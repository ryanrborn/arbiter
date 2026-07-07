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

    test "includes the provider field" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)
      assert Quota.serialize(ws.id).provider == "claude"
    end
  end

  describe "list_latest/1" do
    test "returns an empty list when nothing has been captured" do
      ws = workspace!()
      assert Quota.list_latest(ws.id) == []
    end

    test "returns one row per tracked provider" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)
      {:ok, _} = Quota.capture(ws.id, @headers, provider: "codex")

      providers = ws.id |> Quota.list_latest() |> Enum.map(& &1.provider) |> Enum.sort()
      assert providers == ["claude", "codex"]
    end

    test "does not include another workspace's rows" do
      ws = workspace!()
      other = workspace!("other")
      {:ok, _} = Quota.capture(ws.id, @headers)
      {:ok, _} = Quota.capture(other.id, @headers)

      assert [%{workspace_id: id}] = Quota.list_latest(ws.id)
      assert id == ws.id
    end
  end

  describe "list_serialized/1" do
    test "serializes every tracked provider, each carrying its provider tag" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)
      {:ok, _} = Quota.capture(ws.id, @headers, provider: "codex")

      serialized = Quota.list_serialized(ws.id)
      providers = serialized |> Enum.map(& &1.provider) |> Enum.sort()

      assert providers == ["claude", "codex"]
      assert Enum.all?(serialized, &is_binary(&1.captured_at))
    end
  end

  describe "list_latest/1 multi-provider merge (bd-ajh7bd)" do
    alias Arbiter.Quota.CodexQuota
    alias Arbiter.Quota.GoogleQuota

    defp usage_event!(ws_id, provider, cost) do
      Ash.create!(Arbiter.Usage.Event, %{
        task_id: "cost-#{System.unique_integer([:positive])}",
        step: :work,
        provider: provider,
        cost_usd: cost,
        workspace_id: ws_id,
        occurred_at: DateTime.utc_now()
      })
    end

    test "attaches recent per-provider spend from the usage ledger as cost_usd" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      Ash.create!(CodexQuota, %{
        workspace_id: ws.id,
        provider: "codex",
        session_used_percent: 10.0,
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      # Ledger provider keys ("claude"/"openai"/"gemini") differ from the quota
      # provider codes ("claude"/"codex"/"gemini_cli"); the mapping rolls spend up.
      usage_event!(ws.id, "claude", 1.25)
      usage_event!(ws.id, "claude", 0.75)
      usage_event!(ws.id, "openai", 3.0)

      views = Quota.list_latest(ws.id)
      claude = Enum.find(views, &(&1.provider == "claude"))
      codex = Enum.find(views, &(&1.provider == "codex"))

      assert_in_delta claude.cost_usd, 2.0, 0.0001
      assert_in_delta codex.cost_usd, 3.0, 0.0001
    end

    test "cost_usd is nil for a provider with no ledger spend" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      views = Quota.list_latest(ws.id)
      claude = Enum.find(views, &(&1.provider == "claude"))
      assert claude.cost_usd == nil
    end

    test "folds real Codex + Google rows into the uniform view, claude first" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      Ash.create!(CodexQuota, %{
        workspace_id: ws.id,
        provider: "codex",
        plan: "plus",
        session_used_percent: 42.0,
        weekly_used_percent: 8.0,
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      Ash.create!(GoogleQuota, %{
        workspace_id: ws.id,
        provider: "gemini_cli",
        plan: "Free",
        used_percent: 75.0,
        snapshot: %{"models" => []},
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      views = Quota.list_latest(ws.id)
      providers = Enum.map(views, & &1.provider)

      # claude sorts first; the rest present regardless of order
      assert hd(providers) == "claude"
      assert Enum.sort(providers) == ["claude", "codex", "gemini_cli"]

      # every entry is the uniform view map (not a raw resource struct)
      assert Enum.all?(views, &is_map/1)
      refute Enum.any?(views, &is_struct/1)

      codex = Enum.find(views, &(&1.provider == "codex"))
      assert_in_delta codex.utilization_5h, 0.42, 0.0001
      assert_in_delta codex.utilization_7d, 0.08, 0.0001
      assert codex.primary_label == "session"

      google = Enum.find(views, &(&1.provider == "gemini_cli"))
      assert_in_delta google.utilization_5h, 0.75, 0.0001
    end

    test "the dedicated Codex table wins over a same-provider generic row" do
      ws = workspace!()
      # A generic 'codex' row in the anthropic/quota table (legacy capture path)…
      {:ok, _} = Quota.capture(ws.id, @headers, provider: "codex")

      # …and the real CodexQuota snapshot. Only one 'codex' entry, from the
      # dedicated table.
      Ash.create!(CodexQuota, %{
        workspace_id: ws.id,
        provider: "codex",
        session_used_percent: 90.0,
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      views = Quota.list_latest(ws.id)
      codex_views = Enum.filter(views, &(&1.provider == "codex"))

      assert length(codex_views) == 1
      assert_in_delta hd(codex_views).utilization_5h, 0.90, 0.0001
    end
  end

  describe "google_snapshots/1" do
    test "returns nils when the google fetch is disabled" do
      assert Quota.google_snapshots(enabled: false) == %{gemini: nil, antigravity: nil}
    end

    test "defaults to disabled in the test env (no live network calls)" do
      assert Quota.google_snapshots() == %{gemini: nil, antigravity: nil}
    end

    test "no-ops to nils when enabled but credentials are absent" do
      missing =
        Path.join(System.tmp_dir!(), "absent_#{System.unique_integer([:positive])}.json")

      assert Quota.google_snapshots(enabled: true, creds_path: missing) ==
               %{gemini: nil, antigravity: nil}
    end
  end

  describe "capture_oauth_usage/2" do
    setup do
      on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!("test-token") end)
      :ok
    end

    test "layers per-model utilization + extra_usage onto an existing header-capture row" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "five_hour" => %{"utilization" => 24},
          "seven_day" => %{"utilization" => 8},
          "seven_day_sonnet" => %{"utilization" => 55},
          "seven_day_opus" => %{"utilization" => 5},
          "extra_usage" => 12.5
        })
      end)

      assert {:ok, quota} =
               Quota.capture_oauth_usage(ws.id,
                 token: "test-token",
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )

      assert quota.per_model_utilization == %{"sonnet" => 0.55, "opus" => 0.05}
      assert quota.extra_usage == %{"amount_usd" => 12.5}
      assert quota.oauth_utilization_5h == 0.24
      assert quota.oauth_utilization_7d == 0.08

      # never touches the header-capture columns already on the row
      assert quota.utilization_5h == 0.24
      assert quota.provider == "claude"

      serialized = Quota.serialize(ws.id)
      assert serialized.utilization_5h == 0.24
      assert serialized.per_model_utilization == %{"sonnet" => 0.55, "opus" => 0.05}
      assert serialized.extra_usage == %{"amount_usd" => 12.5}
    end

    test "creates a row on its own when no header-capture snapshot exists yet" do
      ws = workspace!()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Req.Test.json(conn, %{"seven_day_sonnet" => %{"utilization" => 10}})
      end)

      assert {:ok, quota} =
               Quota.capture_oauth_usage(ws.id,
                 token: "test-token",
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )

      assert quota.per_model_utilization == %{"sonnet" => 0.10}
      assert quota.utilization_5h == nil
    end

    test "returns the fetch error and does not touch the snapshot on failure" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, {:http_error, 500}} =
               Quota.capture_oauth_usage(ws.id,
                 token: "test-token",
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )

      assert Quota.serialize(ws.id).per_model_utilization == %{}
    end
  end

  describe "refresh_and_serialize/2" do
    setup do
      on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!("test-token") end)
      :ok
    end

    test "refreshes oauth usage (reading the token off disk) and returns the serialized snapshot" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      dir = Path.join(System.tmp_dir!(), "quota_refresh_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".credentials.json"),
        Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "test-token"}})
      )

      prev_dir = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", dir)
      Application.put_env(:arbiter, :oauth_usage_http_stub, true)

      on_exit(fn ->
        File.rm_rf!(dir)
        Application.put_env(:arbiter, :oauth_usage_http_stub, true)

        if prev_dir do
          System.put_env("CLAUDE_CONFIG_DIR", prev_dir)
        else
          System.delete_env("CLAUDE_CONFIG_DIR")
        end
      end)

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Req.Test.json(conn, %{"seven_day_sonnet" => %{"utilization" => 42}})
      end)

      result = Quota.refresh_and_serialize(ws.id)

      assert result.utilization_5h == 0.24
      assert result.per_model_utilization == %{"sonnet" => 0.42}
    end

    test "still returns the existing snapshot when the oauth fetch fails (no credentials)" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)

      result = Quota.refresh_and_serialize(ws.id)

      assert result.utilization_5h == 0.24
    end

    test "returns nil when nothing has ever been captured, without raising" do
      ws = workspace!()
      assert Quota.refresh_and_serialize(ws.id) == nil
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
