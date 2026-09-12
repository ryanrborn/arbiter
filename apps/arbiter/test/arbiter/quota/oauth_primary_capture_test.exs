defmodule Arbiter.Quota.OAuthPrimaryCaptureTest do
  @moduledoc """
  The polled `/api/oauth/usage` snapshot must drive the dispatch gate on its
  own (bd-b0zody) — no proxied header traffic anywhere in these tests.

  Before this, `Arbiter.Quota.capture_oauth_usage/2` wrote only the secondary
  `oauth_*` columns, so `Gate.gating_window/2` (which reads `utilization_5h` /
  `status_5h` / `captured_at` / ...) saw nothing at all unless a worker had
  recently gone through the proxy.
  """
  # async: false — the OAuthUsage 429 cooldown lives in :persistent_term.
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Overage
  alias Arbiter.Tasks.Workspace

  @headers [
    {"anthropic-ratelimit-unified-5h-utilization", "0.10"},
    {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
    {"anthropic-ratelimit-unified-5h-status", "allowed"},
    {"anthropic-ratelimit-unified-7d-utilization", "0.11"},
    {"anthropic-ratelimit-unified-7d-reset", "1782748800"},
    {"anthropic-ratelimit-unified-7d-status", "allowed"},
    {"anthropic-ratelimit-unified-representative-claim", "five_hour"},
    {"anthropic-ratelimit-unified-overage-status", "allowed"}
  ]

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)
    on_exit(fn -> Quota.OAuthUsage.reset_cooldown!("test-token") end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.merge(prior, on_exhaustion: :throttle, throttle_threshold: 0.85)
      |> Keyword.drop([:weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp workspace!(name \\ "default"), do: Ash.create!(Workspace, %{name: name})

  defp stub_body(overrides) do
    now = DateTime.utc_now()

    body =
      Map.merge(
        %{
          "five_hour" => %{
            "utilization" => 24,
            "resets_at" => now |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          },
          "seven_day" => %{
            "utilization" => 8,
            "resets_at" => now |> DateTime.add(3 * 86_400, :second) |> DateTime.to_iso8601()
          },
          "seven_day_sonnet" => %{"utilization" => 55},
          "extra_usage" => %{"is_enabled" => true},
          "limits" => [%{"group" => "session", "is_active" => true}]
        },
        overrides
      )

    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Req.Test.json(conn, body) end)
  end

  defp poll!(ws, overrides \\ %{}) do
    stub_body(overrides)

    {:ok, quota} =
      Quota.capture_oauth_usage(ws.id,
        token: "test-token",
        plug: {Req.Test, Quota.OAuthUsage.HTTP}
      )

    quota
  end

  describe "capture_oauth_usage/2 writes the primary columns" do
    test "a poll alone populates every column the gate reads" do
      ws = workspace!()
      quota = poll!(ws)

      assert quota.utilization_5h == 0.24
      assert quota.status_5h == "allowed"
      assert %DateTime{} = quota.reset_5h_at
      assert quota.utilization_7d == 0.08
      assert quota.status_7d == "allowed"
      assert %DateTime{} = quota.reset_7d_at
      assert quota.representative_claim == "five_hour"
      assert quota.overage_status == "allowed"
      assert %DateTime{} = quota.captured_at
      assert DateTime.diff(DateTime.utc_now(), quota.captured_at, :second) < 5

      # secondary columns still written, and the provenance marker says who wrote
      assert quota.oauth_utilization_5h == 0.24
      assert quota.per_model_utilization == %{"sonnet" => 0.55}
      assert quota.capture_source == "oauth_poll"
    end

    test "header capture marks its own provenance" do
      ws = workspace!()
      assert {:ok, quota} = Quota.capture(ws.id, @headers)
      assert quota.capture_source == "headers"
    end

    test "a body with no aggregate 5h figure leaves the existing primary row alone" do
      ws = workspace!()
      {:ok, _} = Quota.capture(ws.id, @headers)
      before = Quota.latest(ws.id)

      quota = poll!(ws, %{"five_hour" => nil, "seven_day" => nil, "limits" => nil})

      assert quota.utilization_5h == 0.10
      assert quota.status_5h == "allowed"
      assert quota.representative_claim == "five_hour"
      assert quota.captured_at == before.captured_at
      assert quota.capture_source == "headers"
      # the per-model secondary layer still landed
      assert quota.per_model_utilization == %{"sonnet" => 0.55}
    end

    test "a 429 cooldown leaves the previous row intact rather than writing nils" do
      ws = workspace!()
      polled = poll!(ws)

      Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:error, :rate_limited} =
               Quota.capture_oauth_usage(ws.id,
                 token: "test-token",
                 plug: {Req.Test, Quota.OAuthUsage.HTTP}
               )

      # second call is short-circuited by the cooldown — still no write
      assert {:error, :cooling_down} =
               Quota.capture_oauth_usage(ws.id,
                 token: "test-token",
                 plug: {Req.Test, Quota.OAuthUsage.HTTP}
               )

      after_429 = Quota.latest(ws.id)
      assert after_429.utilization_5h == polled.utilization_5h
      assert after_429.status_5h == polled.status_5h
      assert after_429.reset_5h_at == polled.reset_5h_at
      assert after_429.captured_at == polled.captured_at
      assert after_429.capture_source == "oauth_poll"
    end
  end

  describe "a polled snapshot alone drives Gate.gating_window/2" do
    test "rule 1 — primary status past-plan" do
      ws = workspace!()

      quota =
        poll!(ws, %{
          "five_hour" => %{
            "utilization" => 100,
            "resets_at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        })

      assert %{window: "5h", signal: :status, status: "rejected"} =
               Gate.gating_window(quota, nil)
    end

    test "rule 2 — long-window status rejected" do
      ws = workspace!()

      quota =
        poll!(ws, %{
          "seven_day" => %{
            "utilization" => 12,
            "resets_at" =>
              DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.to_iso8601(),
            "locked_reason" => "manual_review"
          }
        })

      assert %{window: "7d", signal: :status, status: "rejected"} =
               Gate.gating_window(quota, nil)
    end

    test "rule 3 — primary utilization over our own ceiling" do
      ws = workspace!()

      quota =
        poll!(ws, %{
          "five_hour" => %{
            "utilization" => 90,
            # resets in an hour → 80% of the 5h window elapsed, so the CLI's
            # burn-rate warning does not fire and status_5h stays "allowed":
            # this pins the *utilization* rule, not the status rule.
            "resets_at" =>
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        })

      assert %{window: "5h", signal: :utilization, threshold: 0.85} =
               Gate.gating_window(quota, nil)
    end

    test "rule 4 — long-window utilization over the weekly ceiling" do
      ws = workspace!()

      quota =
        poll!(ws, %{
          "seven_day" => %{
            "utilization" => 96,
            "resets_at" =>
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()
          }
        })

      assert %{window: "7d", signal: :utilization} = Gate.gating_window(quota, nil)
    end

    test "rule 5 — long-window allowed_warning under weekly_warning_policy: :hold" do
      ws = workspace!()

      # 7d at 76% with only ~14% of the week elapsed → synthesized
      # allowed_warning, below the 0.95 weekly utilization ceiling.
      resets_at = DateTime.utc_now() |> DateTime.add(round(604_800 * 0.86), :second)

      quota =
        poll!(ws, %{
          "seven_day" => %{
            "utilization" => 76,
            "resets_at" => DateTime.to_iso8601(resets_at)
          }
        })

      assert quota.status_7d == "allowed_warning"
      assert Gate.gating_window(quota, %Workspace{id: ws.id, config: %{}}) == nil

      held = %Workspace{id: ws.id, config: %{"quota" => %{"weekly_warning_policy" => "hold"}}}
      assert %{window: "7d", signal: :warning, status: "allowed_warning"} =
               Gate.gating_window(quota, held)
    end
  end

  describe "downstream consumers of a polled row" do
    test "Overage.window_start/1 derives the 5h window from the polled reset_5h_at" do
      ws = workspace!()
      quota = poll!(ws)

      assert DateTime.compare(
               Overage.window_start(quota),
               DateTime.add(quota.reset_5h_at, -5 * 3600, :second)
             ) == :eq
    end

    test "the serialized view carries representative_claim and the capture source" do
      ws = workspace!()
      _ = poll!(ws)

      serialized = Quota.serialize(ws.id)
      assert serialized.representative_claim == "five_hour"
      assert serialized.capture_source == "oauth_poll"
      assert serialized.stale == false

      view = Quota.list_latest(ws.id) |> Enum.find(&(&1.provider == "claude"))
      assert view.representative_claim == "five_hour"
      assert view.capture_source == "oauth_poll"
    end
  end

  describe "staleness margin for polled rows" do
    test "a polled row survives one missed poll; a header row of the same age does not" do
      ws = workspace!()
      quota = poll!(ws)

      # 400s: past the 300s header threshold, inside the 600s polled threshold.
      aged = %{quota | captured_at: DateTime.add(DateTime.utc_now(), -400, :second)}

      refute Gate.stale?(aged)
      assert Gate.stale?(%{aged | capture_source: "headers"})
      assert Gate.stale?(%{aged | capture_source: nil})
    end

    test "a polled row does go stale after two missed polls" do
      ws = workspace!()
      quota = poll!(ws)

      aged = %{quota | captured_at: DateTime.add(DateTime.utc_now(), -601, :second)}
      assert Gate.stale?(aged)
    end

    test "the polled threshold is configurable" do
      Application.put_env(
        :arbiter,
        :quota,
        Keyword.merge(Application.get_env(:arbiter, :quota, []),
          polled_staleness_threshold_seconds: 120
        )
      )

      ws = workspace!()
      quota = poll!(ws)

      aged = %{quota | captured_at: DateTime.add(DateTime.utc_now(), -150, :second)}
      assert Gate.stale?(aged)
    end
  end
end
