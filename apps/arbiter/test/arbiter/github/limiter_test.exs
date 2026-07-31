defmodule Arbiter.GitHub.LimiterTest do
  # async: true — each test starts its OWN isolated Limiter instance via
  # `start_supervised!` with a unique name, so there is no shared global state
  # between tests (the app-wide singleton is never touched here).
  use ExUnit.Case, async: true

  alias Arbiter.GitHub.Limiter

  @token "pat_aaa"
  @other_token "pat_bbb"

  # A test-controlled clock: an Agent holding the "current" DateTime so
  # secondary-backoff expiry can be driven deterministically.
  defp start_clock(base) do
    {:ok, agent} = Agent.start_link(fn -> base end)
    clock_fun = fn -> Agent.get(agent, & &1) end
    {agent, clock_fun}
  end

  defp advance(agent, seconds) do
    Agent.update(agent, fn dt -> DateTime.add(dt, seconds, :second) end)
  end

  # Start an isolated limiter with probing disabled (no real HTTP): pool
  # resolution falls back to :shared, which is exactly the fail-safe default we
  # want to exercise deterministically.
  defp start_limiter(opts) do
    name = :"limiter_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Limiter, Keyword.merge([name: name, probe: false], opts)}
    )

    name
  end

  describe "acquire/3 priority classes" do
    test "foreground is always allowed, even with zero headroom and an active secondary backoff" do
      srv = start_limiter(background_headroom: 1000)
      # Drive remaining to 0 and arm a secondary backoff.
      Limiter.observe(@token, %{remaining: 0, limit: 5000, reset_at: nil}, srv)
      Limiter.note_secondary(@token, srv)

      assert :ok = Limiter.acquire(@token, :foreground, srv)
      assert :ok = Limiter.acquire(@token, :foreground, srv)
    end

    test "background is allowed when headroom is comfortable" do
      srv = start_limiter(background_headroom: 1000)
      Limiter.observe(@token, %{remaining: 4999, limit: 5000, reset_at: nil}, srv)

      assert :ok = Limiter.acquire(@token, :background, srv)
    end

    test "background pauses once remaining drops to/below the reserved headroom" do
      srv = start_limiter(background_headroom: 1000)
      Limiter.observe(@token, %{remaining: 1000, limit: 5000, reset_at: nil}, srv)

      assert {:paused, :low_headroom} = Limiter.acquire(@token, :background, srv)

      # ...but foreground still gets through the reserved band.
      assert :ok = Limiter.acquire(@token, :foreground, srv)
    end

    test "with no observation yet, background is allowed (nothing says we are low)" do
      srv = start_limiter(background_headroom: 1000)
      assert :ok = Limiter.acquire(@token, :background, srv)
    end
  end

  describe "secondary rate limit (403 with headroom showing)" do
    test "note_secondary pauses background for the cooldown, then clears" do
      base = ~U[2026-07-31 18:00:00Z]
      {agent, clock_fun} = start_clock(base)

      srv =
        start_limiter(
          background_headroom: 100,
          secondary_cooldown_ms: 120_000,
          clock_fun: clock_fun
        )

      # Plenty of primary headroom — this is purely the secondary limit.
      Limiter.observe(@token, %{remaining: 4000, limit: 5000, reset_at: nil}, srv)
      Limiter.note_secondary(@token, srv)

      assert {:paused, :secondary_backoff} = Limiter.acquire(@token, :background, srv)
      # Foreground is never starved, even during a hard secondary backoff.
      assert :ok = Limiter.acquire(@token, :foreground, srv)

      # Just before the cooldown elapses: still paused.
      advance(agent, 119)
      assert {:paused, :secondary_backoff} = Limiter.acquire(@token, :background, srv)

      # After the cooldown: background resumes.
      advance(agent, 2)
      assert :ok = Limiter.acquire(@token, :background, srv)
    end
  end

  describe "pool identity" do
    test "unresolved credentials share the :shared pool (fail safe toward under-issuing)" do
      srv = start_limiter([])
      assert :shared = Limiter.pool_for(@token, srv)
      assert :shared = Limiter.pool_for(@other_token, srv)
    end

    test "two tokens that share a pool are throttled together" do
      srv = start_limiter(background_headroom: 1000)
      # Both tokens resolve to :shared (probe off), so an observation via one is
      # visible to the other — one budget, not two.
      Limiter.observe(@token, %{remaining: 500, limit: 5000, reset_at: nil}, srv)

      assert {:paused, :low_headroom} = Limiter.acquire(@other_token, :background, srv)
    end
  end

  describe "pool identity resolution (owning account)" do
    # A resolver that maps tokens to accounts, so the sharing logic is exercised
    # without any live `GET /user` traffic.
    defp account_resolver do
      fn
        "pat_a" -> {:ok, "acct-1"}
        "pat_b" -> {:ok, "acct-1"}
        "pat_c" -> {:ok, "acct-2"}
        _ -> :error
      end
    end

    defp await_pool(srv, token, expected) do
      Enum.reduce_while(1..100, :timeout, fn _, _ ->
        if Limiter.pool_for(token, srv) == expected do
          {:halt, expected}
        else
          Process.sleep(5)
          {:cont, :timeout}
        end
      end)
    end

    test "two tokens owned by the same account share one budget; a different account does not" do
      srv = start_limiter(probe: true, resolver_fun: account_resolver(), background_headroom: 1000)

      assert await_pool(srv, "pat_a", {:account, "acct-1"}) == {:account, "acct-1"}
      assert await_pool(srv, "pat_b", {:account, "acct-1"}) == {:account, "acct-1"}
      assert await_pool(srv, "pat_c", {:account, "acct-2"}) == {:account, "acct-2"}

      # Saturate acct-1 via token A; token B (same account) is throttled with it.
      Limiter.observe("pat_a", %{remaining: 500, limit: 5000, reset_at: nil}, srv)
      assert {:paused, :low_headroom} = Limiter.acquire("pat_b", :background, srv)

      # Token C (a different account) is a separate pool — untouched.
      assert :ok = Limiter.acquire("pat_c", :background, srv)
    end

    test "a resolver failure leaves the token on the :shared pool (fail safe)" do
      srv = start_limiter(probe: true, resolver_fun: account_resolver())
      # "pat_unknown" resolves to :error → stays :shared, and stays usable.
      assert :shared = Limiter.pool_for("pat_unknown", srv)
      assert :ok = Limiter.acquire("pat_unknown", :foreground, srv)
    end
  end

  describe "parse_headers/1" do
    test "reads GitHub's x-ratelimit-* headers (the /rate_limit-driven signal)" do
      headers = %{
        "x-ratelimit-remaining" => ["2807"],
        "x-ratelimit-limit" => ["5000"],
        "x-ratelimit-reset" => ["1753900000"]
      }

      assert %{remaining: 2807, limit: 5000, reset_at: %DateTime{}} =
               Limiter.parse_headers(headers)
    end

    test "tolerates missing headers (all nil, nothing clobbered on observe)" do
      assert %{remaining: nil, limit: nil, reset_at: nil} = Limiter.parse_headers(%{})
    end
  end

  describe "stats/1 observability" do
    test "counts requests by priority class, including paused background" do
      srv = start_limiter(background_headroom: 1000)
      Limiter.observe(@token, %{remaining: 4999, limit: 5000, reset_at: nil}, srv)

      :ok = Limiter.acquire(@token, :foreground, srv)
      :ok = Limiter.acquire(@token, :foreground, srv)
      :ok = Limiter.acquire(@token, :background, srv)

      Limiter.observe(@token, %{remaining: 500, limit: 5000, reset_at: nil}, srv)
      {:paused, _} = Limiter.acquire(@token, :background, srv)

      stats = Limiter.stats(srv)
      pool = stats[:shared]

      assert pool.counts.foreground == 2
      assert pool.counts.background == 1
      assert pool.counts.background_paused == 1
      assert pool.remaining == 500
    end
  end

  describe "with_priority/2 process context" do
    test "sets and restores the ambient priority for the current process" do
      assert Limiter.current_priority() == :foreground

      result =
        Limiter.with_priority(:background, fn ->
          Limiter.current_priority()
        end)

      assert result == :background
      # Restored afterwards.
      assert Limiter.current_priority() == :foreground
    end
  end
end
