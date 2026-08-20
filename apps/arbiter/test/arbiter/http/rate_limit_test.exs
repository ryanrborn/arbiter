defmodule Arbiter.Http.RateLimitTest do
  use ExUnit.Case, async: true

  alias Arbiter.Http.RateLimit

  defp resp(headers) do
    Enum.reduce(headers, Req.Response.new(status: 403), fn {k, v}, acc ->
      Req.Response.put_header(acc, k, v)
    end)
  end

  describe "retry_after_seconds/1" do
    test "parses an integer Retry-After header" do
      assert RateLimit.retry_after_seconds(resp([{"retry-after", "5"}])) == 5
    end

    test "parses a zero Retry-After header" do
      assert RateLimit.retry_after_seconds(resp([{"retry-after", "0"}])) == 0
    end

    test "is nil when the header is absent" do
      assert RateLimit.retry_after_seconds(resp([])) == nil
    end

    test "is nil when the header is unparseable" do
      assert RateLimit.retry_after_seconds(resp([{"retry-after", "soon"}])) == nil
    end

    # The merger copy guarded on `n >= 0`; the tracker copy did not. The shared
    # helper keeps the stricter guard so a bogus negative header can never
    # produce a negative backoff.
    test "is nil for a negative Retry-After header" do
      assert RateLimit.retry_after_seconds(resp([{"retry-after", "-5"}])) == nil
    end
  end

  describe "reset_retry_after_ms/1" do
    test "converts x-ratelimit-reset (unix epoch seconds) into ms from now" do
      epoch = System.os_time(:second) + 60
      ms = RateLimit.reset_retry_after_ms(resp([{"x-ratelimit-reset", to_string(epoch)}]))

      assert is_integer(ms)
      assert ms > 50_000 and ms <= 60_000
    end

    test "is nil for a reset already in the past" do
      epoch = System.os_time(:second) - 60

      assert RateLimit.reset_retry_after_ms(resp([{"x-ratelimit-reset", to_string(epoch)}])) ==
               nil
    end

    test "is nil when the header is absent or unparseable" do
      assert RateLimit.reset_retry_after_ms(resp([])) == nil
      assert RateLimit.reset_retry_after_ms(resp([{"x-ratelimit-reset", "nope"}])) == nil
    end
  end

  describe "retry_after_ms/2" do
    test "prefers Retry-After over x-ratelimit-reset" do
      epoch = System.os_time(:second) + 600
      r = resp([{"retry-after", "5"}, {"x-ratelimit-reset", to_string(epoch)}])

      assert RateLimit.retry_after_ms(429, r) == 5_000
      assert RateLimit.retry_after_ms(403, r) == 5_000
    end

    test "falls back to x-ratelimit-reset when Retry-After is absent" do
      epoch = System.os_time(:second) + 30
      ms = RateLimit.retry_after_ms(403, resp([{"x-ratelimit-reset", to_string(epoch)}]))

      assert is_integer(ms)
      assert ms > 20_000 and ms <= 30_000
    end

    test "is nil for statuses that are not rate limits" do
      assert RateLimit.retry_after_ms(404, resp([{"retry-after", "5"}])) == nil
      assert RateLimit.retry_after_ms(500, resp([{"retry-after", "5"}])) == nil
    end

    test "is nil when no response was captured" do
      assert RateLimit.retry_after_ms(429, nil) == nil
      assert RateLimit.retry_after_ms(403, nil) == nil
    end
  end
end
