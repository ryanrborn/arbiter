defmodule Arbiter.Workflows.PatrolPacing do
  @moduledoc """
  Pure pacing helpers shared by `PRPatrol` and `ReviewPatrol` (bd-4brb2j):
  jitter so N patrols started within milliseconds of each other at boot don't
  keep ticking in lockstep forever, and exponential idle backoff so a patrol
  that finds nothing to do stops holding a fixed ~1/min cadence.

  Kept as a separate, state-free module (rather than folded into either
  patrol) because the two patrols are deliberately separate modules/registries
  — see `ReviewPatrolSupervisor`'s moduledoc — but this pacing math has no
  patrol-specific behavior worth duplicating.

  `Arbiter.Reviews.PrStatePoller` reuses `idle_backoff_ms/3` too (bd-7qgxf9),
  per *record* rather than per patrol: the shape of the problem — "this thing
  found nothing new again, so stop asking so often" — is identical, and the
  background GitHub budget it protects is the same one.
  """

  # +/- 15%: enough to desynchronize 18 patrols started within the same
  # ~20ms boot window without meaningfully changing anyone's effective cadence.
  @jitter_ratio 0.15

  @doc """
  Apply +/- #{@jitter_ratio * 100}% jitter to a delay, so that patrols sharing
  the same nominal interval drift apart instead of ticking in lockstep. Always
  returns a positive integer.
  """
  @spec jitter(pos_integer()) :: pos_integer()
  def jitter(ms) when is_integer(ms) and ms > 0 do
    spread = max(round(ms * @jitter_ratio), 1)
    offset = :rand.uniform(spread * 2 + 1) - spread - 1
    max(ms + offset, 1)
  end

  @doc """
  Exponential backoff for a patrol that has found nothing to act on for
  `idle_streak` consecutive ticks: `base * 2^idle_streak`, capped at
  `ceiling_ms`. A streak of 0 (a patrol that has never gone idle, or whose
  last tick found something actionable) returns the base interval unchanged;
  the very first idle tick already doubles the interval, growing further with
  each consecutive idle tick until the ceiling is hit.

  `base_ms` falls back to 60_000 when not a positive integer, so a
  misconfigured/zero interval can't collapse this into a zero-delay loop.
  """
  # Above this, `base * 2^exponent` already exceeds any realistic ceiling_ms,
  # so clamping the exponent here avoids recomputing an ever-larger bignum on
  # every schedule for a patrol that's been idle for weeks/months.
  @max_exponent 32

  @spec idle_backoff_ms(non_neg_integer(), integer(), pos_integer()) :: pos_integer()
  def idle_backoff_ms(idle_streak, base_ms, ceiling_ms)
      when is_integer(idle_streak) and idle_streak >= 0 do
    base = if is_integer(base_ms) and base_ms > 0, do: base_ms, else: 60_000
    min(base * Integer.pow(2, min(idle_streak, @max_exponent)), ceiling_ms)
  end
end
