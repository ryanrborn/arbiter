defmodule Arbiter.CircuitBreakerTest do
  @moduledoc """
  Core unit tests for the shared circuit breaker (bd-5jr49o / #1632):
  trip, suppression, window expiry, reset, and signature normalisation.

  Every test drives the clock explicitly through `now:` rather than sleeping,
  so window expiry is deterministic.
  """
  use ExUnit.Case, async: false

  alias Arbiter.CircuitBreaker

  @ws "ws-cb-test"

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)
    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [workspace_id: @ws, limit: 3, window_ms: 60_000, escalate: false],
      extra
    )
  end

  describe "check/3 — trip and suppression" do
    test "allows the first K identical triggers, then suppresses" do
      for _ <- 1..3 do
        assert :allow = CircuitBreaker.check(:test_kind, "same subject", opts())
      end

      assert {:suppress, info} = CircuitBreaker.check(:test_kind, "same subject", opts())
      assert info.count == 4
      assert info.limit == 3
      assert info.window_ms == 60_000
      assert info.signature =~ "test_kind"

      # and stays suppressed
      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "same subject", opts())
    end

    test "reports the trip exactly once, then reports subsequent calls as already-open" do
      for _ <- 1..3, do: CircuitBreaker.check(:test_kind, "s", opts())

      assert {:suppress, %{tripped_now?: true}} = CircuitBreaker.check(:test_kind, "s", opts())
      assert {:suppress, %{tripped_now?: false}} = CircuitBreaker.check(:test_kind, "s", opts())
      assert {:suppress, %{tripped_now?: false}} = CircuitBreaker.check(:test_kind, "s", opts())
    end

    test "distinct subjects get independent budgets" do
      for _ <- 1..3, do: assert(:allow = CircuitBreaker.check(:test_kind, "a", opts()))
      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "a", opts())

      assert :allow = CircuitBreaker.check(:test_kind, "b", opts())
    end

    test "distinct kinds with the same subject get independent budgets" do
      for _ <- 1..3, do: assert(:allow = CircuitBreaker.check(:kind_a, "s", opts()))
      assert {:suppress, _} = CircuitBreaker.check(:kind_a, "s", opts())

      assert :allow = CircuitBreaker.check(:kind_b, "s", opts())
    end

    test "distinct workspaces with the same kind+subject get independent budgets" do
      for _ <- 1..3, do: assert(:allow = CircuitBreaker.check(:test_kind, "s", opts()))
      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "s", opts())

      assert :allow = CircuitBreaker.check(:test_kind, "s", opts(workspace_id: "other-ws"))
    end
  end

  describe "window expiry" do
    test "closes once the window passes with no further triggers" do
      t0 = 1_000_000

      for i <- 0..2 do
        assert :allow = CircuitBreaker.check(:test_kind, "s", opts(now: t0 + i))
      end

      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "s", opts(now: t0 + 3))

      # Still inside the window: suppressed.
      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "s", opts(now: t0 + 59_000))

      # Past the window measured from the most recent trigger: closed again.
      assert :allow = CircuitBreaker.check(:test_kind, "s", opts(now: t0 + 59_000 + 60_001))
    end

    test "a sustained flood keeps the breaker open (suppressed attempts refresh the window)" do
      t0 = 1_000_000
      for i <- 0..2, do: CircuitBreaker.check(:test_kind, "s", opts(now: t0 + i))

      # One trigger every 30s for an hour: never allowed again.
      for i <- 1..120 do
        assert {:suppress, _} =
                 CircuitBreaker.check(:test_kind, "s", opts(now: t0 + i * 30_000))
      end
    end

    test "a closed-then-reopened breaker escalates again" do
      t0 = 1_000_000
      for i <- 0..2, do: CircuitBreaker.check(:test_kind, "s", opts(now: t0 + i))
      assert {:suppress, %{tripped_now?: true}} = CircuitBreaker.check(:test_kind, "s", opts(now: t0 + 3))

      later = t0 + 500_000
      for i <- 0..2, do: assert(:allow = CircuitBreaker.check(:test_kind, "s", opts(now: later + i)))

      assert {:suppress, %{tripped_now?: true}} =
               CircuitBreaker.check(:test_kind, "s", opts(now: later + 3))
    end
  end

  describe "reset" do
    test "reset/1 by signature reopens the budget" do
      for _ <- 1..3, do: CircuitBreaker.check(:test_kind, "s", opts())
      assert {:suppress, info} = CircuitBreaker.check(:test_kind, "s", opts())

      assert :ok = CircuitBreaker.reset(info.signature)
      assert :allow = CircuitBreaker.check(:test_kind, "s", opts())
    end

    test "reset/1 on an unknown signature is an error, not a crash" do
      assert {:error, :not_found} = CircuitBreaker.reset("no-such-signature")
    end

    test "reset_all/1 scoped to a workspace leaves other workspaces alone" do
      for _ <- 1..4, do: CircuitBreaker.check(:test_kind, "s", opts())
      for _ <- 1..4, do: CircuitBreaker.check(:test_kind, "s", opts(workspace_id: "keep-ws"))

      assert {:ok, 1} = CircuitBreaker.reset_all(workspace_id: @ws)

      assert :allow = CircuitBreaker.check(:test_kind, "s", opts())
      assert {:suppress, _} = CircuitBreaker.check(:test_kind, "s", opts(workspace_id: "keep-ws"))
    end
  end

  describe "list/1" do
    test "returns live breaker state with counts, window and open flag" do
      for _ <- 1..4, do: CircuitBreaker.check(:test_kind, "subject one", opts())

      assert [entry] = CircuitBreaker.list(workspace_id: @ws)
      assert entry.kind == :test_kind
      assert entry.workspace_id == @ws
      assert entry.count == 4
      assert entry.limit == 3
      assert entry.window_ms == 60_000
      assert entry.open? == true
      assert entry.suppressed == 1
      assert entry.subject == "subject one"
    end

    test "reports a below-limit breaker as closed" do
      CircuitBreaker.check(:test_kind, "s", opts())
      assert [%{open?: false, count: 1}] = CircuitBreaker.list(workspace_id: @ws)
    end
  end

  describe "call_sites/0" do
    test "enumerates every adopted call site with its kind, module and defaults" do
      sites = CircuitBreaker.call_sites()
      kinds = Enum.map(sites, & &1.kind)

      for kind <- [
            :pr_patrol_follow_up,
            :watchdog_merge_escalation,
            :preflight_auth_failed,
            :dispatch_queue_redispatch,
            :coordinator_escalation
          ] do
        assert kind in kinds, "expected #{kind} to be a registered breaker call site"
      end

      for site <- sites do
        assert is_atom(site.kind)
        assert is_binary(site.description)
        assert is_atom(site.module)
        assert is_integer(site.limit) and site.limit > 0
        assert is_integer(site.window_ms) and site.window_ms > 0
      end
    end

    test "every registered kind resolves its configured limit and window" do
      for %{kind: kind, limit: limit, window_ms: window_ms} <- CircuitBreaker.call_sites() do
        assert CircuitBreaker.limit_for(kind) == limit
        assert CircuitBreaker.window_for(kind) == window_ms
      end
    end
  end

  describe "guard/4" do
    test "runs the function while closed and skips it once open" do
      me = self()
      fun = fn -> send(me, :ran) end

      for _ <- 1..3, do: assert({:ok, _} = CircuitBreaker.guard(:test_kind, "s", opts(), fun))
      assert_received :ran
      assert_received :ran
      assert_received :ran

      assert {:suppressed, _info} = CircuitBreaker.guard(:test_kind, "s", opts(), fun)
      refute_received :ran
    end

    test "a raising function does not corrupt the breaker" do
      assert_raise RuntimeError, fn ->
        CircuitBreaker.guard(:test_kind, "s", opts(), fn -> raise "boom" end)
      end

      assert [%{count: 1}] = CircuitBreaker.list(workspace_id: @ws)
    end
  end
end
