defmodule Arbiter.Quota.Pace do
  @approaching_margin 0.10
  @sampling_floor 0.05

  @moduledoc """
  The per-window pace verdict (bd-clzkvp): the one definition of "ahead of
  pace" that both the dispatch gate and the quota bars read.

  `evaluate/4` is pure. It takes one window's utilization, how far into the
  window we are, the window's length, and the thresholds that apply to it,
  and returns a verdict:

    * `:holding` — `utilization >= ceiling`. This is exactly the condition
      under which `Arbiter.Quota.Gate` holds dispatch on the window's
      utilization rule; the gate makes that decision through this function.
    * `:approaching` — within `#{@approaching_margin}` (ten percentage points of the window)
      of the ceiling: `utilization >= ceiling - #{@approaching_margin}`. On a paced ceiling
      that is the last tenth of a window's worth of on-pace burn before the
      gate would hold — 30 minutes of a 5h window, about 17 hours of a 7d one.
    * `:sampling` — neither of the above, and either less than `#{@sampling_floor}` of
      the window has elapsed (15 minutes of 5h, ~8.4 hours of 7d) or less
      than `#{@sampling_floor}` of it is used. Too early or too little to call a pace.
    * `:ok` — none of the above, including no utilization reading at all.

  `:holding` and `:approaching` outrank `:sampling`: a paced floor makes the
  ceiling meaningful from the first second, so the gate holds however early a
  window is, and the verdict must say so.

  ## The ceiling

  The thresholds argument is `%{sides: [side], default: ceiling}` — the
  gate's `min(account, workspace)` composition, already resolved into one
  entry per side that configured anything:

    * `{:paced, floor, flat_fallback}` — `max(floor, elapsed)`, where
      `elapsed` is the elapsed fraction of the window; without a known
      `elapsed` (no window length, no reset) it falls back to the side's own
      flat ceiling, or drops out when it has none.
    * `{:flat, ceiling}` — a fixed ceiling.

  Each side is turned into a number for *now* and the smallest wins, ties
  going to the earlier side; with no side left, `default` applies. See
  "Threshold modes" in `Arbiter.Quota.Gate` for where each number comes from.
  """

  @type verdict :: :ok | :approaching | :holding | :sampling
  @type side :: {:paced, float(), float() | nil} | {:flat, float()}
  @type thresholds :: %{sides: [side()], default: float()}

  @typedoc """
  `ceiling` is the threshold in force at the moment of the check, `mode` says
  whether pacing produced it, and `elapsed` is the elapsed fraction of the
  window (`nil` when unknown).
  """
  @type t :: %{
          verdict: verdict(),
          ceiling: float(),
          mode: :paced | :flat,
          elapsed: float() | nil
        }

  @doc "How far below the ceiling `:approaching` starts, as a fraction of the window."
  @spec approaching_margin() :: float()
  def approaching_margin, do: @approaching_margin

  @doc """
  The pace verdict for one window. `elapsed_seconds` is how far into the window
  the check is (see `elapsed_seconds/3`); either it or `window_seconds` being
  `nil` means the elapsed fraction is unknown and paced sides fall back.
  """
  @spec evaluate(number() | nil, number() | nil, pos_integer() | nil, thresholds()) :: t()
  def evaluate(utilization, elapsed_seconds, window_seconds, %{sides: sides, default: default}) do
    elapsed = elapsed_fraction(elapsed_seconds, window_seconds)

    {ceiling, mode} =
      sides
      |> Enum.map(&side_ceiling(&1, elapsed))
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {c, _mode} -> c end, fn -> {default, :flat} end)

    %{
      verdict: verdict(utilization, ceiling, elapsed),
      ceiling: ceiling,
      mode: mode,
      elapsed: elapsed
    }
  end

  @doc """
  Seconds elapsed in a window of `window_seconds` that resets at `reset_at`,
  as of `now`. `nil` when either is unknown. Unclamped — `evaluate/4` clamps.
  """
  @spec elapsed_seconds(DateTime.t() | nil, pos_integer() | nil, DateTime.t()) :: float() | nil
  def elapsed_seconds(%DateTime{} = reset_at, window_seconds, %DateTime{} = now)
      when is_integer(window_seconds) do
    window_seconds - DateTime.diff(reset_at, now, :millisecond) / 1000
  end

  def elapsed_seconds(_reset_at, _window_seconds, _now), do: nil

  defp elapsed_fraction(elapsed, window) when is_number(elapsed) and is_integer(window) do
    (elapsed / window) |> max(0.0) |> min(1.0)
  end

  defp elapsed_fraction(_elapsed, _window), do: nil

  defp side_ceiling({:paced, floor, _flat}, elapsed) when is_float(elapsed),
    do: {max(floor, elapsed), :paced}

  defp side_ceiling({:paced, _floor, nil}, _elapsed), do: nil
  defp side_ceiling({:paced, _floor, flat}, _elapsed), do: {flat, :flat}
  defp side_ceiling({:flat, ceiling}, _elapsed), do: {ceiling, :flat}

  defp verdict(u, ceiling, elapsed) when is_number(u) do
    cond do
      u >= ceiling -> :holding
      u >= ceiling - @approaching_margin -> :approaching
      sampling?(u, elapsed) -> :sampling
      true -> :ok
    end
  end

  defp verdict(_u, _ceiling, _elapsed), do: :ok

  defp sampling?(u, elapsed),
    do: u < @sampling_floor or (is_float(elapsed) and elapsed < @sampling_floor)
end
