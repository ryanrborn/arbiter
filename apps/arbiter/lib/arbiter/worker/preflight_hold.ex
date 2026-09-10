defmodule Arbiter.Worker.PreflightHold do
  @moduledoc """
  Shared policy for "when should the next pre-flight dispatch attempt happen"
  after a `:quota_exhausted` pre-flight failure (bd-8lnnnt).

  Two callers re-attempt a dispatch whose pre-flight probe already failed on
  an exhausted 5h usage window, on two different clocks:

    * `Arbiter.Board.Autopilot` — the 15s board tick.
    * `Arbiter.Workflows.DispatchQueue` — the held-intent drain, woken by
      `Arbiter.Quota.RefreshProbe`/`CloudProbe` PubSub broadcasts (every
      5 minutes) and by its own deterministic reset-time timer.

  Both need the same answer to "is it worth re-running the doomed CLI probe
  right now", so the policy lives here once rather than twice: prefer the
  probe's own reported reset time (`StopReason.retry_after`) when known — the
  account provably cannot dispatch before then no matter how often the caller
  ticks — and fall back to a bounded exponential backoff when no reset time
  was parsed out of the CLI's failure text.
  """

  alias Arbiter.Worker.StopReason

  @backoff_base_ms :timer.seconds(30)
  @backoff_max_ms :timer.minutes(15)
  @reset_buffer_ms :timer.seconds(60)
  @max_backoff_exponent 10

  @doc """
  Returns the earliest time the next pre-flight attempt should run, or `nil`
  when this failure shouldn't hold at all (anything other than a
  quota-exhausted `auth_check_failed`).

  `count` is the number of consecutive same-shape failures (>= 1); only used
  for the backoff fallback.
  """
  @spec retry_not_before(term(), pos_integer(), DateTime.t()) :: DateTime.t() | nil
  def retry_not_before(
        {:auth_check_failed,
         %StopReason{category: :quota_exhausted, retry_after: %DateTime{} = at}},
        _count,
        _now
      ) do
    DateTime.add(at, @reset_buffer_ms, :millisecond)
  end

  def retry_not_before(
        {:auth_check_failed, %StopReason{category: :quota_exhausted}},
        count,
        now
      ) do
    exponent = min(count - 1, @max_backoff_exponent)
    backoff_ms = min(@backoff_base_ms * Integer.pow(2, exponent), @backoff_max_ms)
    DateTime.add(now, backoff_ms, :millisecond)
  end

  def retry_not_before(_reason, _count, _now), do: nil
end
