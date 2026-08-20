defmodule Arbiter.Http.ClientTest do
  use ExUnit.Case, async: false

  alias Arbiter.Http.Client
  alias Arbiter.Http.Error, as: ErrorSpec

  # Reuse two real provider error structs so the shared client is exercised
  # against the exact shapes it has to keep producing: one without a
  # `retry_after_ms` field, one with.
  alias Arbiter.Mergers.Github.Error, as: RateLimitedError
  alias Arbiter.Trackers.Shortcut.Error, as: PlainError

  @stub_name Arbiter.Http.ClientTest.HTTP
  @stub_env :arbiter_http_client_test_stub

  setup do
    Application.put_env(:arbiter, @stub_env, true)
    on_exit(fn -> Application.delete_env(:arbiter, @stub_env) end)
    :ok
  end

  defp classify_kind(401, _body), do: :unauthenticated
  defp classify_kind(404, _body), do: :not_found
  defp classify_kind(status, _body) when status in [403, 429], do: :rate_limited
  defp classify_kind(_status, _body), do: :http

  defp error_message(%{"message" => msg}, _status) when is_binary(msg), do: msg
  defp error_message(_body, status), do: "HTTP #{status}"

  defp errors(overrides \\ []) do
    [
      module: PlainError,
      classify_kind: &classify_kind/2,
      error_message: &error_message/2
    ]
    |> Keyword.merge(overrides)
    |> ErrorSpec.new()
  end

  defp client(overrides \\ []) do
    [
      base_url: "https://api.example.test/v1",
      headers: [{"authorization", "Bearer tok"}, {"user-agent", "arbiter"}],
      errors: errors(),
      stub: {@stub_env, @stub_name}
    ]
    |> Keyword.merge(overrides)
    |> Client.new()
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  describe "build_opts/4" do
    test "joins base_url with path and carries headers, timeout and retry: false" do
      opts = Client.build_opts(client(), :get, "/issues/7", [])

      assert opts[:method] == :get
      assert opts[:url] == "https://api.example.test/v1/issues/7"
      assert opts[:headers] == [{"authorization", "Bearer tok"}, {"user-agent", "arbiter"}]
      assert opts[:receive_timeout] == 15_000
      assert opts[:retry] == false
    end

    test "caller req_opts win over the defaults" do
      opts = Client.build_opts(client(), :post, "/x", json: %{a: 1}, receive_timeout: 1_000)

      assert opts[:json] == %{a: 1}
      assert opts[:receive_timeout] == 1_000
    end

    test "injects the stub plug only while the stub env flag is set" do
      assert Client.build_opts(client(), :get, "/x", [])[:plug] == {Req.Test, @stub_name}

      Application.put_env(:arbiter, @stub_env, false)
      refute Keyword.has_key?(Client.build_opts(client(), :get, "/x", []), :plug)

      refute Keyword.has_key?(
               Client.build_opts(client(stub: nil), :get, "/x", []),
               :plug
             )
    end

    test "an explicit per-call plug is not clobbered by stub injection" do
      opts = Client.build_opts(client(stub: nil), :get, "/x", plug: {Req.Test, :other})
      assert opts[:plug] == {Req.Test, :other}
    end
  end

  describe "request/4" do
    test "performs the request and returns the raw Req result" do
      stub(fn conn ->
        assert conn.request_path == "/v1/issues/7"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
        Req.Test.json(conn, %{"id" => 7})
      end)

      assert {:ok, %Req.Response{status: 200, body: %{"id" => 7}}} =
               Client.request(client(), :get, "/issues/7", [])
    end

    test "routes every attempt through the configured gate" do
      test_pid = self()

      gate = fn fun ->
        send(test_pid, :gated)
        fun.()
      end

      stub(fn conn -> Req.Test.json(conn, %{}) end)

      assert {:ok, %Req.Response{status: 200}} =
               Client.request(client(gate: gate), :get, "/x", [])

      assert_received :gated
    end
  end

  describe "handle_json/2 and expect_ok/2" do
    test "2xx yields the decoded body / :ok" do
      assert Client.handle_json(client(), {:ok, Req.Response.new(status: 204, body: %{"a" => 1})}) ==
               {:ok, %{"a" => 1}}

      assert Client.expect_ok(client(), {:ok, Req.Response.new(status: 201, body: "x")}) == :ok
    end

    test "non-2xx yields a classified provider error" do
      resp = Req.Response.new(status: 404, body: %{"message" => "Not Found"})

      assert {:error, %PlainError{kind: :not_found, status: 404, message: "Not Found", raw: raw}} =
               Client.handle_json(client(), {:ok, resp})

      assert raw == %{"message" => "Not Found"}

      assert {:error, %PlainError{kind: :not_found, status: 404}} =
               Client.expect_ok(client(), {:ok, resp})
    end

    test "falls back to HTTP <status> when the body carries no message" do
      assert {:error, %PlainError{message: "HTTP 500"}} =
               Client.handle_json(client(), {:ok, Req.Response.new(status: 500, body: "")})
    end

    test "a transport failure becomes a :network error carrying the exception" do
      ex = %Req.TransportError{reason: :timeout}

      assert {:error, %PlainError{kind: :network, status: nil, raw: ^ex, message: msg}} =
               Client.handle_json(client(), {:error, ex})

      assert msg == Exception.message(ex)

      assert {:error, %PlainError{kind: :network, message: "\"boom\""}} =
               Client.expect_ok(client(), {:error, "boom"})
    end

    test "retry_after_ms is populated when the client configures a resolver" do
      c =
        client(
          errors:
            errors(
              module: RateLimitedError,
              retry_after_ms: &Arbiter.Http.RateLimit.retry_after_ms/2
            )
        )

      resp =
        Req.Response.new(status: 429, body: %{"message" => "rate limit"})
        |> Req.Response.put_header("retry-after", "5")

      assert {:error, %RateLimitedError{kind: :rate_limited, retry_after_ms: 5_000}} =
               Client.handle_json(c, {:ok, resp})
    end

    test "a bare error spec works without a client (no request config needed)" do
      spec = errors()

      assert Client.handle_json(spec, {:ok, Req.Response.new(status: 200, body: "b")}) ==
               {:ok, "b"}

      assert {:error, %PlainError{kind: :not_found}} =
               Client.handle_json(spec, {:ok, Req.Response.new(status: 404, body: %{})})

      assert {:error, %PlainError{kind: :network}} =
               Client.expect_ok(spec, {:error, %Req.TransportError{reason: :closed}})
    end

    test "retry_after_ms stays unset when no resolver is configured" do
      c = client(errors: errors(module: RateLimitedError))

      assert {:error, %RateLimitedError{retry_after_ms: nil}} =
               Client.handle_json(c, {:ok, Req.Response.new(status: 429, body: %{})})
    end
  end

  describe "retry policy" do
    setup do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      %{counter: counter}
    end

    defp retrying_client(counter, overrides \\ []) do
      test_pid = self()

      client(
        Keyword.merge(
          [
            retry: %{
              max: 2,
              retry?: fn resp -> resp.status in [403, 429] end,
              delay: fn _resp, attempt -> 10 * (attempt + 1) end,
              sleep: fn ms -> send(test_pid, {:slept, ms}) end,
              on_retry: fn _resp, attempt -> send(test_pid, {:retrying, attempt}) end
            }
          ],
          overrides
        )
      )
      |> tap(fn _ -> counter end)
    end

    test "retries a retryable response up to max attempts, then returns it", %{counter: counter} do
      stub(fn conn ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(self(), {:attempt, n})
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "slow down"})
      end)

      assert {:ok, %Req.Response{status: 403}} =
               Client.request(retrying_client(counter), :get, "/x", [])

      assert Agent.get(counter, & &1) == 3
      assert_received {:retrying, 0}
      assert_received {:slept, 10}
      assert_received {:retrying, 1}
      assert_received {:slept, 20}
    end

    test "stops retrying as soon as a response is not retryable", %{counter: counter} do
      stub(fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{})
          _ -> Req.Test.json(conn, %{"ok" => true})
        end
      end)

      assert {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
               Client.request(retrying_client(counter), :get, "/x", [])

      assert Agent.get(counter, & &1) == 2
    end

    test "does not retry transport failures", %{counter: counter} do
      stub(fn conn ->
        Agent.update(counter, &(&1 + 1))
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, _} = Client.request(retrying_client(counter), :get, "/x", [])
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "paginate/4" do
    test "follows next_page, transforms each page and flattens the result" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            conn
            |> Plug.Conn.put_resp_header("x-next", "2")
            |> Req.Test.json([%{"n" => 1}, %{"skip" => true}])

          _ ->
            Req.Test.json(conn, [%{"n" => 2}])
        end
      end)

      next_page = fn headers, path, req_opts ->
        case headers do
          %{"x-next" => [page | _]} -> {path, Keyword.put(req_opts, :params, page: page)}
          _ -> nil
        end
      end

      assert {:ok, [%{"n" => 1}, %{"n" => 2}]} =
               Client.paginate(client(), "/issues", [],
                 max_pages: 50,
                 next_page: next_page,
                 transform_page: fn page -> Enum.reject(page, &Map.has_key?(&1, "skip")) end
               )

      assert Agent.get(counter, & &1) == 2
    end

    test "stops at max_pages even when the API keeps offering a next page" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("x-next", "9")
        |> Req.Test.json([%{"n" => 1}])
      end)

      next_page = fn _headers, path, req_opts -> {path, req_opts} end

      assert {:ok, pages} =
               Client.paginate(client(), "/issues", [], max_pages: 2, next_page: next_page)

      assert length(pages) == 2
      assert Agent.get(counter, & &1) == 2
    end

    test "a non-2xx page aborts with a classified error" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "nope"})
      end)

      assert {:error, %PlainError{kind: :unauthenticated, message: "nope"}} =
               Client.paginate(client(), "/issues", [],
                 max_pages: 5,
                 next_page: fn _, _, _ -> nil end
               )
    end

    test "a transport failure aborts with a :network error" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %PlainError{kind: :network}} =
               Client.paginate(client(), "/issues", [],
                 max_pages: 5,
                 next_page: fn _, _, _ -> nil end
               )
    end

    test "a non-list body is treated as an empty page" do
      stub(fn conn -> Req.Test.json(conn, %{"not" => "a list"}) end)

      assert {:ok, []} =
               Client.paginate(client(), "/issues", [],
                 max_pages: 5,
                 next_page: fn _, _, _ -> nil end
               )
    end
  end
end
