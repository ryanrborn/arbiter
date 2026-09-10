defmodule Arbiter.Worker.PreflightHoldTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.PreflightHold
  alias Arbiter.Worker.StopReason

  describe "retry_not_before/3" do
    test "prefers the probe's own reported reset time, plus a buffer" do
      now = DateTime.utc_now()
      reset_at = DateTime.add(now, 3600, :second)

      reason =
        {:auth_check_failed,
         %StopReason{category: :quota_exhausted, summary: "s", retry_after: reset_at}}

      assert PreflightHold.retry_not_before(reason, 1, now) ==
               DateTime.add(reset_at, 60, :second)
    end

    test "falls back to a bounded exponential backoff with no known reset time" do
      now = DateTime.utc_now()

      reason =
        {:auth_check_failed,
         %StopReason{category: :quota_exhausted, summary: "s", retry_after: nil}}

      first = PreflightHold.retry_not_before(reason, 1, now)
      second = PreflightHold.retry_not_before(reason, 2, now)
      capped = PreflightHold.retry_not_before(reason, 50, now)

      assert DateTime.diff(first, now, :millisecond) == 30_000
      assert DateTime.diff(second, now, :millisecond) == 60_000
      # A huge count must clamp to the 15-minute cap, not evaluate an
      # unbounded `Integer.pow/2`.
      assert DateTime.diff(capped, now, :millisecond) == :timer.minutes(15)
    end

    test "no hold for any other failure shape" do
      now = DateTime.utc_now()

      assert PreflightHold.retry_not_before(:always_fails, 1, now) == nil

      assert PreflightHold.retry_not_before(
               {:auth_check_failed, %StopReason{category: :auth_expired, summary: "s"}},
               1,
               now
             ) == nil
    end
  end
end
