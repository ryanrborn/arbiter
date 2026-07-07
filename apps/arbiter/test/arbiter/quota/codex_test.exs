defmodule Arbiter.Quota.CodexTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.Codex
  alias Arbiter.Tasks.Workspace

  @stub_name Arbiter.Quota.Codex.HTTP

  # A representative 200 body, mirroring the shape 9router's `getCodexUsage`
  # parses: a `rate_limit` object with `primary_window` (session) and
  # `secondary_window` (weekly), each with a used-percent and a reset time.
  @usage_body %{
    "plan_type" => "plus",
    "rate_limit" => %{
      "primary_window" => %{"used_percent" => 42.5, "reset_at" => 1_782_247_200},
      "secondary_window" => %{"used_percent" => 8.0, "reset_at" => 1_782_748_800}
    }
  }

  defp workspace!(name \\ "default"), do: Ash.create!(Workspace, %{name: name})

  defp creds, do: %{access_token: "tok-abc", account_id: "acct-123"}

  describe "normalize/1" do
    test "extracts session + weekly windows from rate_limit.primary/secondary" do
      assert {:ok, attrs} = Codex.normalize(@usage_body)

      assert attrs.plan == "plus"
      assert attrs.session_used_percent == 42.5
      assert attrs.weekly_used_percent == 8.0
      assert DateTime.to_unix(attrs.session_reset_at) == 1_782_247_200
      assert DateTime.to_unix(attrs.weekly_reset_at) == 1_782_748_800
    end

    test "accepts the rate_limits alias and percent_used/resets_at keys" do
      body = %{
        "rate_limits" => %{
          "primary_window" => %{"percent_used" => 10.0, "resets_at" => 1_782_247_200}
        }
      }

      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.session_used_percent == 10.0
      # absent window → key omitted, so the upsert leaves the column nil
      refute Map.has_key?(attrs, :weekly_used_percent)
      assert DateTime.to_unix(attrs.session_reset_at) == 1_782_247_200
    end

    test "accepts rate_limits_by_limit_id.codex" do
      body = %{
        "rate_limits_by_limit_id" => %{
          "codex" => %{
            "secondary_window" => %{"used_percent" => 55.0, "resetAt" => "2026-06-24T00:00:00Z"}
          }
        }
      }

      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.weekly_used_percent == 55.0
      assert %DateTime{} = attrs.weekly_reset_at
    end

    test "clamps used-percent into 0..100" do
      body = %{"rate_limit" => %{"primary_window" => %{"used_percent" => 250.0}}}
      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.session_used_percent == 100.0
    end

    test "is a no-op when no window data is present" do
      assert Codex.normalize(%{"plan_type" => "plus"}) == :noop
      assert Codex.normalize(%{}) == :noop
    end
  end

  describe "fetch/2 — credentials absent" do
    test "no-op with a message, and makes no HTTP call" do
      ws = workspace!()

      result = Codex.fetch(ws.id, auth_path: "/nonexistent/codex/auth.json")

      assert result.codex == nil
      assert result.message =~ "not authenticated"
      assert Codex.latest(ws.id) == nil
    end
  end

  describe "fetch/2 — happy path" do
    setup do
      Application.put_env(:arbiter, :codex_quota_http_stub, true)
      on_exit(fn -> Application.delete_env(:arbiter, :codex_quota_http_stub) end)
      :ok
    end

    test "upserts a snapshot and returns the normalized windows" do
      ws = workspace!()

      Req.Test.stub(@stub_name, fn conn ->
        assert ["Bearer tok-abc"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["acct-123"] = Plug.Conn.get_req_header(conn, "chatgpt-account-id")
        Req.Test.json(conn, @usage_body)
      end)

      result = Codex.fetch(ws.id, credentials: creds())

      assert result.message == nil
      assert result.codex.plan == "plus"
      assert result.codex.session.used == 42.5
      assert result.codex.session.remaining == 57.5
      assert result.codex.session.total == 100
      assert result.codex.weekly.used == 8.0
      assert is_binary(result.codex.session.reset_at)

      # persisted, readable back
      row = Codex.latest(ws.id)
      assert row.session_used_percent == 42.5
      assert row.weekly_used_percent == 8.0
    end

    test "broadcasts the uniform {:quota_updated, ws, view} so LiveView picks it up (bd-ajh7bd)" do
      ws = workspace!()
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{ws.id}")

      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, @usage_body) end)

      Codex.fetch(ws.id, credentials: creds())

      # Same message shape the Anthropic/Google paths emit — a uniform view map,
      # provider "codex", session→5h fraction — not the legacy
      # {:codex_quota_updated, ws, %CodexQuota{}} struct the LiveView ignored.
      assert_receive {:quota_updated, ws_id, view}, 2_000
      assert ws_id == ws.id
      assert is_map(view) and not is_struct(view)
      assert view.provider == "codex"
      assert_in_delta view.utilization_5h, 0.425, 0.0001
    end
  end

  describe "fetch/2 — degrade path" do
    setup do
      Application.put_env(:arbiter, :codex_quota_http_stub, true)
      on_exit(fn -> Application.delete_env(:arbiter, :codex_quota_http_stub) end)
      :ok
    end

    test "401 (expired token) skips the cycle gracefully without writing a snapshot" do
      ws = workspace!()

      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => "token_expired"}})
      end)

      result = Codex.fetch(ws.id, credentials: creds())

      assert result.codex == nil
      assert result.message =~ "401"
      assert Codex.latest(ws.id) == nil
    end
  end

  describe "read_credentials/1" do
    test "reads access_token + account_id from a codex auth.json" do
      path = Path.join(System.tmp_dir!(), "codex_auth_#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "tokens" => %{"access_token" => "AT", "account_id" => "AID"}
        })
      )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{access_token: "AT", account_id: "AID"}} =
               Codex.read_credentials(auth_path: path)
    end

    test "errors when the file is absent" do
      assert {:error, _} = Codex.read_credentials(auth_path: "/nope/auth.json")
    end
  end
end
