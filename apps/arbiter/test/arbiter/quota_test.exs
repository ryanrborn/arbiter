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

    test "includes stale indicator (false for fresh snapshots)" do
      # Lower staleness threshold temporarily for testing
      Application.put_env(:arbiter, :quota, staleness_threshold_seconds: 60)
      on_exit(fn -> restore_test_env() end)

      ws = workspace!()

      # Use headers with a future reset time so the snapshot isn't stale by reset_at
      future_reset = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.to_unix()

      headers = [
        {"anthropic-ratelimit-unified-5h-utilization", "0.24"},
        {"anthropic-ratelimit-unified-5h-reset", Integer.to_string(future_reset)},
        {"anthropic-ratelimit-unified-5h-status", "allowed"},
        {"anthropic-ratelimit-unified-7d-utilization", "0.08"},
        {"anthropic-ratelimit-unified-7d-reset", "1782748800"},
        {"anthropic-ratelimit-unified-7d-status", "allowed"},
        {"anthropic-ratelimit-unified-representative-claim", "five_hour"},
        {"anthropic-ratelimit-unified-overage-status", "rejected"},
        {"content-type", "application/json"}
      ]

      {:ok, _} = Quota.capture(ws.id, headers)
      serialized = Quota.serialize(ws.id)

      # Fresh snapshot (just captured) should not be stale
      refute serialized.stale
    end

    test "stale indicator is true for old snapshots" do
      # Use a very short threshold for testing
      Application.put_env(:arbiter, :quota, staleness_threshold_seconds: 2)
      on_exit(fn -> restore_test_env() end)

      ws = workspace!()
      {:ok, _quota} = Quota.capture(ws.id, @headers)

      # Manually update the DB row's captured_at to be old using raw SQL
      old_time = DateTime.utc_now() |> DateTime.add(-5, :second)

      {:ok, _} =
        Arbiter.Repo.query(
          "UPDATE anthropic_quotas SET captured_at = ? WHERE workspace_id = ? AND provider = 'claude'",
          [old_time, ws.id]
        )

      serialized = Quota.serialize(ws.id)

      # Old snapshot should be stale
      assert serialized.stale == true
    end

    defp restore_test_env do
      Application.put_env(:arbiter, :quota,
        on_exhaustion: :throttle,
        throttle_threshold: 0.85,
        overage_alert_usd: 50.0
      )
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

  describe "default_workspace_on_exhaustion/0 (bd-l4epbc)" do
    test "delegates to Workspace.quota_on_exhaustion/1 for whichever workspace default_workspace_id/0 resolves" do
      # `Workspace.quota_on_exhaustion/1`'s own precedence rules (per-workspace
      # override > global default > hardcoded :throttle) are covered in
      # `Arbiter.Quota.Gate.GateTest`; this only proves the wiring — that this
      # reads the SAME workspace `default_workspace_id/0` resolves, not a
      # hardcoded/mismatched one.
      case Quota.default_workspace_id() do
        {:ok, ws_id} ->
          workspace = Ash.get!(Workspace, ws_id)

          assert Quota.default_workspace_on_exhaustion() ==
                   Workspace.quota_on_exhaustion(workspace)

        {:error, _} ->
          assert Quota.default_workspace_on_exhaustion() == Workspace.quota_on_exhaustion(nil)
      end
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

    test "no-ops gemini to nil when credentials are absent; antigravity degrades instead of nil-ing (bd-d7hmqn)" do
      # `:creds_path` isolates `gemini/1`, which still returns `nil` when its
      # creds file is absent. `antigravity/1` no longer reads any stored
      # token — it shells out to the `agy` CLI — so it never returns `nil`;
      # stub `:agy_usage_probe` so this test doesn't depend on whether `agy`
      # is actually installed on the host running the suite.
      missing =
        Path.join(System.tmp_dir!(), "absent_#{System.unique_integer([:positive])}.json")

      result =
        Quota.google_snapshots(
          enabled: true,
          creds_path: missing,
          agy_usage_probe: fn -> {:error, :not_installed} end
        )

      assert result.gemini == nil
      refute is_nil(result.antigravity)
      assert result.antigravity.message =~ "not installed"
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

      # bd-b0zody: the poll now also refreshes the primary columns the gate
      # reads, so this row no longer depends on proxied traffic staying warm.
      assert quota.utilization_5h == 0.24
      assert quota.capture_source == "oauth_poll"
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

  describe "capture_oauth_usage_for_group/2" do
    setup do
      on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!("test-token") end)
      :ok
    end

    test "fetches once and writes the same snapshot to every workspace in the group" do
      ws_a = workspace!("a")
      ws_b = workspace!("b")
      ws_c = workspace!("c")

      test_pid = self()

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        send(test_pid, :http_call)

        Req.Test.json(conn, %{
          "five_hour" => %{"utilization" => 24},
          "seven_day_sonnet" => %{"utilization" => 55}
        })
      end)

      assert {:ok, results} =
               Quota.capture_oauth_usage_for_group([ws_a.id, ws_b.id, ws_c.id],
                 token: "test-token",
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )

      assert length(results) == 3
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # exactly one HTTP request for the whole group
      assert_received :http_call
      refute_received :http_call

      for ws <- [ws_a, ws_b, ws_c] do
        serialized = Quota.serialize(ws.id)
        assert serialized.oauth_utilization_5h == 0.24
        assert serialized.per_model_utilization == %{"sonnet" => 0.55}
      end
    end

    test "propagates the fetch error without writing any workspace" do
      ws_a = workspace!("a")
      ws_b = workspace!("b")

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, {:http_error, 500}} =
               Quota.capture_oauth_usage_for_group([ws_a.id, ws_b.id],
                 token: "test-token",
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )

      assert Quota.serialize(ws_a.id) == nil
      assert Quota.serialize(ws_b.id) == nil
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
end
