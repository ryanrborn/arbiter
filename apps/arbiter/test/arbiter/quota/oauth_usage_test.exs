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
      tmp = System.tmp_dir!() |> Path.join("oauth_usage_test_#{System.unique_integer([:positive])}")
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
      tmp = System.tmp_dir!() |> Path.join("oauth_usage_test_missing_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :no_credentials} = OAuthUsage.fetch(source_dir: tmp)
    end
  end
end
