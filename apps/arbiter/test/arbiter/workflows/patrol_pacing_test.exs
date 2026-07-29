defmodule Arbiter.Workflows.PatrolPacingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.PatrolPacing

  describe "jitter/1" do
    test "returns a value within +/- 15% of the input" do
      base = 60_000
      spread = round(base * 0.15)

      for _ <- 1..200 do
        jittered = PatrolPacing.jitter(base)
        assert jittered >= base - spread
        assert jittered <= base + spread
      end
    end

    test "never returns a negative or zero delay for a tiny input" do
      for _ <- 1..50 do
        assert PatrolPacing.jitter(1) > 0
      end
    end
  end

  describe "idle_backoff_ms/3" do
    test "streak 0 (never idle yet) stays at the base interval" do
      assert PatrolPacing.idle_backoff_ms(0, 60_000, 900_000) == 60_000
    end

    test "grows exponentially with consecutive idle ticks" do
      assert PatrolPacing.idle_backoff_ms(1, 60_000, 900_000) == 120_000
      assert PatrolPacing.idle_backoff_ms(2, 60_000, 900_000) == 240_000
      assert PatrolPacing.idle_backoff_ms(3, 60_000, 900_000) == 480_000
    end

    test "caps at the given ceiling regardless of how large the streak grows" do
      assert PatrolPacing.idle_backoff_ms(20, 60_000, 900_000) == 900_000
      assert PatrolPacing.idle_backoff_ms(1_000_000, 60_000, 900_000) == 900_000
    end

    test "a non-positive base interval falls back to a sane default rather than looping forever" do
      assert PatrolPacing.idle_backoff_ms(3, 0, 900_000) > 0
    end
  end
end
