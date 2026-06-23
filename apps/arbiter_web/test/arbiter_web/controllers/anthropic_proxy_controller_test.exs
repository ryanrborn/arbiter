defmodule ArbiterWeb.AnthropicProxyControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  # ---- stub upstream standing in for api.anthropic.com -------------------

  defmodule Upstream do
    @moduledoc false
    import Plug.Conn

    @quota [
      {"anthropic-ratelimit-unified-5h-utilization", "0.24"},
      {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
      {"anthropic-ratelimit-unified-5h-status", "allowed"},
      {"anthropic-ratelimit-unified-7d-utilization", "0.08"},
      {"anthropic-ratelimit-unified-7d-reset", "1782748800"},
      {"anthropic-ratelimit-unified-7d-status", "allowed"},
      {"anthropic-ratelimit-unified-representative-claim", "five_hour"},
      {"anthropic-ratelimit-unified-overage-status", "rejected"}
    ]

    def init(opts), do: opts

    def call(conn, _opts) do
      auth = conn |> get_req_header("authorization") |> List.first() || ""

      conn =
        conn
        |> merge_resp_headers(@quota)
        |> put_resp_header("x-echo-authorization", auth)
        |> put_resp_header("x-echo-path", conn.request_path)
        |> put_resp_header("set-cookie", "sess=secret")
        |> put_resp_header("cf-ray", "abc123")

      if String.contains?(conn.query_string, "sse") do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, "event: message_start\ndata: {\"type\":\"start\"}\n\n")
        {:ok, conn} = chunk(conn, "event: content_block_delta\ndata: {\"text\":\"hello\"}\n\n")
        {:ok, conn} = chunk(conn, "event: message_stop\ndata: {}\n\n")
        conn
      else
        {:ok, body, conn} = read_body(conn)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{ok: true, echo: body}))
      end
    end
  end

  setup do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)

    start_supervised!({Bandit, plug: Upstream, scheme: :http, port: port})
    Application.put_env(:arbiter_web, :anthropic_upstream, "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.delete_env(:arbiter_web, :anthropic_upstream) end)

    ws = Ash.create!(Workspace, %{name: "default"})
    {:ok, ws: ws}
  end

  describe "health check" do
    test "responds 200 to the empty-path probe without forwarding", %{conn: conn, ws: ws} do
      conn = dispatch(conn, @endpoint, "HEAD", "/proxy/anthropic/#{ws.id}/")
      assert conn.status == 200
      # nothing captured: we never touched upstream
      assert Quota.latest(ws.id) == nil
    end

    test "responds 200 to the bare proxy root", %{conn: conn} do
      conn = dispatch(conn, @endpoint, "HEAD", "/proxy/anthropic")
      assert conn.status == 200
    end

    test "the no-path fallback clause answers 200", %{conn: conn} do
      conn = ArbiterWeb.AnthropicProxyController.forward(conn, %{})
      assert conn.status == 200
    end
  end

  describe "non-streaming forward" do
    test "forwards method/body/headers and returns the JSON response", %{conn: conn, ws: ws} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer sk-oauth-token")
        |> put_req_header("content-type", "application/json")
        |> post(~s(/proxy/anthropic/#{ws.id}/v1/messages?beta=true), ~s({"model":"claude"}))

      assert resp.status == 200
      assert resp.resp_body =~ ~s("ok":true)
      # request body forwarded verbatim
      assert resp.resp_body =~ ~s({\\"model\\":\\"claude\\"})
      # auth header passed through untouched
      assert get_resp_header(resp, "x-echo-authorization") == ["Bearer sk-oauth-token"]
      # workspace segment stripped before upstream
      assert get_resp_header(resp, "x-echo-path") == ["/v1/messages"]
    end

    test "strips set-cookie and Cloudflare headers from the response", %{conn: conn, ws: ws} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~s(/proxy/anthropic/#{ws.id}/v1/messages), "{}")

      assert get_resp_header(resp, "set-cookie") == []
      assert get_resp_header(resp, "cf-ray") == []
      assert get_resp_header(resp, "content-type") |> hd() =~ "application/json"
    end

    test "captures the unified rate-limit headers into the workspace's quota", %{
      conn: conn,
      ws: ws
    } do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~s(/proxy/anthropic/#{ws.id}/v1/messages), "{}")

      quota = Quota.latest(ws.id)
      assert quota.utilization_5h == 0.24
      assert quota.utilization_7d == 0.08
      assert quota.status_5h == "allowed"
      assert quota.representative_claim == "five_hour"
      assert quota.overage_status == "rejected"
    end

    test "attributes to the default workspace when no workspace segment is present", %{
      conn: conn,
      ws: ws
    } do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~s(/proxy/anthropic/v1/messages), "{}")

      assert Quota.latest(ws.id).utilization_5h == 0.24
    end
  end

  describe "upstream failure" do
    test "returns 502 when the upstream is unreachable", %{conn: conn, ws: ws} do
      # Find a free port and point upstream at it without binding — connection refused.
      {:ok, lsock} = :gen_tcp.listen(0, [:binary])
      {:ok, dead_port} = :inet.port(lsock)
      :gen_tcp.close(lsock)
      Application.put_env(:arbiter_web, :anthropic_upstream, "http://127.0.0.1:#{dead_port}")

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~s(/proxy/anthropic/#{ws.id}/v1/messages), "{}")

      assert resp.status == 502
      assert resp.resp_body =~ "proxy_error"
    end
  end

  describe "streaming (SSE) forward" do
    test "streams event-stream chunks back to the client", %{conn: conn, ws: ws} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post(~s(/proxy/anthropic/#{ws.id}/v1/messages?stream=sse), "{}")

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") |> hd() =~ "text/event-stream"
      assert resp.resp_body =~ "message_start"
      assert resp.resp_body =~ "hello"
      assert resp.resp_body =~ "message_stop"
      # quota is still captured on a streamed response
      assert Quota.latest(ws.id).utilization_5h == 0.24
    end
  end
end
