defmodule Arbiter.Quota.OAuthUsageTest do
  # async: false — the 429 cooldown lives in :persistent_term (VM-global).
  use ExUnit.Case, async: false

  alias Arbiter.Quota.OAuthUsage

  defp stub(fun), do: Req.Test.stub(OAuthUsage.HTTP, fun)

  setup do
    on_exit(fn -> OAuthUsage.reset_cooldown!("test-token") end)
    :ok
  end

  describe "fetch/1" do
    test "parses aggregate + per-model utilization and extra_usage from a 200" do
      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["oauth-2025-04-20"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

        Req.Test.json(conn, %{
          "five_hour" => %{"utilization" => 42, "resets_at" => "2026-07-06T12:00:00Z"},
          "seven_day" => %{"utilization" => 10},
          "seven_day_sonnet" => %{"utilization" => 55},
          "seven_day_opus" => %{"utilization" => 5},
          "extra_usage" => 12.5
        })
      end)

      assert {:ok, usage} = OAuthUsage.fetch(token: "test-token")
      assert usage.utilization_5h == 0.42
      assert usage.utilization_7d == 0.10
      assert usage.per_model_utilization == %{"sonnet" => 0.55, "opus" => 0.05}
      assert usage.extra_usage == %{"amount_usd" => 12.5}
    end

    test "treats a nil extra_usage as an empty map" do
      stub(fn conn ->
        Req.Test.json(conn, %{"five_hour" => %{"utilization" => 1}, "extra_usage" => nil})
      end)

      assert {:ok, usage} = OAuthUsage.fetch(token: "test-token")
      assert usage.extra_usage == %{}
    end

    test "starts a cooldown on a 429 and skips the next call without hitting the network" do
      Req.Test.stub(OAuthUsage.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert {:error, :rate_limited} = OAuthUsage.fetch(token: "test-token")

      # A stub that would blow up if called again — proves the second fetch
      # never reaches the network while cooling down.
      Req.Test.stub(OAuthUsage.HTTP, fn _conn -> flunk("should not call the network again") end)

      assert {:error, :cooling_down} = OAuthUsage.fetch(token: "test-token")
    end

    test "surfaces a non-200/429 status as an http_error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:http_error, 500}} = OAuthUsage.fetch(token: "test-token")
    end

    test "reads the token from .credentials.json when none is passed" do
      tmp =
        System.tmp_dir!() |> Path.join("oauth_usage_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(
        Path.join(tmp, ".credentials.json"),
        Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "from-disk-token"}})
      )

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer from-disk-token"]
        Req.Test.json(conn, %{})
      end)

      on_exit(fn -> OAuthUsage.reset_cooldown!("from-disk-token") end)

      assert {:ok, _usage} = OAuthUsage.fetch(source_dir: tmp)
    end

    test "errors when there is no credentials file to read" do
      tmp =
        System.tmp_dir!()
        |> Path.join("oauth_usage_test_missing_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :no_credentials} = OAuthUsage.fetch(source_dir: tmp)
    end
  end

  describe "fetch/1 — resets_at, representative_claim, overage_status, status synthesis" do
    # A recorded shape of the real /api/oauth/usage body (2026-09-12), with no
    # token values — see bd-3uwku6. `resets_at` timestamps are placeholders,
    # overridden per-test below.
    defp fixture(overrides) do
      %{
        "five_hour" => %{
          "utilization" => 42,
          "resets_at" => "2026-07-06T12:00:00Z",
          "limit_dollars" => 140,
          "used_dollars" => 58.8,
          "remaining_dollars" => 81.2,
          "locked_reason" => nil
        },
        "seven_day" => %{
          "utilization" => 10,
          "resets_at" => "2026-07-10T00:00:00Z",
          "limit_dollars" => 1000,
          "used_dollars" => 100,
          "remaining_dollars" => 900,
          "locked_reason" => nil
        },
        "seven_day_sonnet" => %{"utilization" => 55},
        "seven_day_opus" => %{"utilization" => 5},
        "seven_day_breakdown" => nil,
        "seven_day_cowork" => nil,
        "limits" => [
          %{
            "kind" => "session",
            "group" => "session",
            "percent" => 42,
            "severity" => "normal",
            "resets_at" => "2026-07-06T12:00:00Z",
            "is_active" => true,
            "scope" => "account"
          },
          %{
            "kind" => "weekly_all",
            "group" => "weekly",
            "percent" => 10,
            "severity" => "normal",
            "resets_at" => "2026-07-10T00:00:00Z",
            "is_active" => false,
            "scope" => "account"
          }
        ],
        "extra_usage" => %{
          "is_enabled" => true,
          "monthly_limit" => 2000,
          "used_credits" => 66,
          "utilization" => 3.3,
          "currency" => "usd",
          "decimal_places" => 2,
          "disabled_reason" => nil,
          "user_disabled" => false,
          "spend_limit_reached" => false,
          "credits_ever_enabled" => true,
          "daily" => nil,
          "weekly" => nil
        },
        "member_dashboard_available" => true
      }
      |> Map.merge(overrides)
    end

    defp fetch_fixture(overrides \\ %{}) do
      stub(fn conn -> Req.Test.json(conn, fixture(overrides)) end)
      assert {:ok, usage} = OAuthUsage.fetch(token: "test-token")
      usage
    end

    test "parses reset_5h_at / reset_7d_at from resets_at, truncated to the second" do
      usage = fetch_fixture()

      assert usage.reset_5h_at == ~U[2026-07-06 12:00:00Z]
      assert usage.reset_7d_at == ~U[2026-07-10 00:00:00Z]
    end

    test "representative_claim maps the active limits[] entry's group" do
      usage = fetch_fixture()
      assert usage.representative_claim == "five_hour"

      usage =
        fetch_fixture(%{
          "limits" => [
            %{"group" => "session", "is_active" => false},
            %{"group" => "weekly", "is_active" => true}
          ]
        })

      assert usage.representative_claim == "seven_day"
    end

    test "representative_claim is nil when no limits entry is active or limits is missing" do
      usage =
        fetch_fixture(%{
          "limits" => [
            %{"group" => "session", "is_active" => false},
            %{"group" => "weekly", "is_active" => false}
          ]
        })

      assert usage.representative_claim == nil

      usage = fetch_fixture(%{"limits" => nil})
      assert usage.representative_claim == nil
    end

    test "overage_status is allowed when extra_usage is enabled and not spend-capped" do
      usage = fetch_fixture()
      assert usage.overage_status == "allowed"
    end

    test "overage_status is rejected when extra_usage.is_enabled is false" do
      usage =
        fetch_fixture(%{
          "extra_usage" => %{
            "is_enabled" => false,
            "user_disabled" => true,
            "disabled_reason" => nil,
            "spend_limit_reached" => false
          }
        })

      assert usage.overage_status == "rejected"
    end

    test "overage_status is rejected when spend_limit_reached is true" do
      usage =
        fetch_fixture(%{
          "extra_usage" => %{
            "is_enabled" => true,
            "spend_limit_reached" => true,
            "disabled_reason" => nil
          }
        })

      assert usage.overage_status == "rejected"
    end

    test "overage_status is rejected when disabled_reason is present" do
      usage =
        fetch_fixture(%{
          "extra_usage" => %{
            "is_enabled" => true,
            "spend_limit_reached" => false,
            "disabled_reason" => "fraud_review"
          }
        })

      assert usage.overage_status == "rejected"
    end

    test "overage_status is nil when extra_usage is missing or not a map" do
      usage = fetch_fixture(%{"extra_usage" => nil})
      assert usage.overage_status == nil

      usage = fetch_fixture(%{"extra_usage" => 12.5})
      assert usage.overage_status == nil
    end

    test "status_5h / status_7d are rejected when utilization is >= 100" do
      usage =
        fetch_fixture(%{
          "five_hour" => %{"utilization" => 100, "resets_at" => "2026-07-06T12:00:00Z"}
        })

      assert usage.status_5h == "rejected"
    end

    test "status_5h / status_7d are rejected when locked_reason is present, regardless of utilization" do
      usage =
        fetch_fixture(%{
          "seven_day" => %{
            "utilization" => 10,
            "resets_at" => "2026-07-10T00:00:00Z",
            "locked_reason" => "manual_review"
          }
        })

      assert usage.status_7d == "rejected"
    end

    test "status is nil when the window sub-object is missing or utilization is absent" do
      usage = fetch_fixture(%{"five_hour" => nil})
      assert usage.status_5h == nil
      assert usage.reset_5h_at == nil

      usage = fetch_fixture(%{"seven_day" => %{"resets_at" => "2026-07-10T00:00:00Z"}})
      assert usage.status_7d == nil
    end

    test "status_5h warns at the elapsed-fraction boundary (>= 0.90 util, <= 0.72 elapsed)" do
      now = DateTime.utc_now()
      window = 18_000

      # elapsed_fraction ~ 0.71 (inside threshold) -> warn
      inside_resets_at = DateTime.add(now, round(window * (1 - 0.71)), :second)

      usage =
        fetch_fixture(%{
          "five_hour" => %{
            "utilization" => 90,
            "resets_at" => DateTime.to_iso8601(inside_resets_at)
          }
        })

      assert usage.status_5h == "allowed_warning"

      # elapsed_fraction ~ 0.73 (outside threshold) -> no warn
      outside_resets_at = DateTime.add(now, round(window * (1 - 0.73)), :second)

      usage =
        fetch_fixture(%{
          "five_hour" => %{
            "utilization" => 90,
            "resets_at" => DateTime.to_iso8601(outside_resets_at)
          }
        })

      assert usage.status_5h == "allowed"
    end

    test "status_5h does not warn below the 0.90 utilization threshold" do
      now = DateTime.utc_now()
      window = 18_000
      inside_resets_at = DateTime.add(now, round(window * (1 - 0.71)), :second)

      usage =
        fetch_fixture(%{
          "five_hour" => %{
            "utilization" => 89,
            "resets_at" => DateTime.to_iso8601(inside_resets_at)
          }
        })

      assert usage.status_5h == "allowed"
    end

    test "status_7d warns at each of its three threshold rows" do
      now = DateTime.utc_now()
      window = 604_800

      for {util, elapsed_inside} <- [{75, 0.59}, {50, 0.34}, {25, 0.14}] do
        resets_at = DateTime.add(now, round(window * (1 - elapsed_inside)), :second)

        usage =
          fetch_fixture(%{
            "seven_day" => %{
              "utilization" => util,
              "resets_at" => DateTime.to_iso8601(resets_at)
            }
          })

        assert usage.status_7d == "allowed_warning",
               "expected warning at util=#{util} elapsed=#{elapsed_inside}"
      end
    end

    test "status_7d does not warn once elapsed fraction passes each threshold row" do
      now = DateTime.utc_now()
      window = 604_800

      for {util, elapsed_outside} <- [{75, 0.61}, {50, 0.36}, {25, 0.16}] do
        resets_at = DateTime.add(now, round(window * (1 - elapsed_outside)), :second)

        usage =
          fetch_fixture(%{
            "seven_day" => %{
              "utilization" => util,
              "resets_at" => DateTime.to_iso8601(resets_at)
            }
          })

        assert usage.status_7d == "allowed",
               "expected no warning at util=#{util} elapsed=#{elapsed_outside}"
      end
    end

    test "member_dashboard_available and unmodeled null sub-objects don't raise" do
      usage = fetch_fixture(%{"seven_day_breakdown" => nil, "member_dashboard_available" => nil})
      assert usage.status_5h in [nil, "allowed", "allowed_warning", "rejected"]
    end
  end
end
