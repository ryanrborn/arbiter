defmodule Arbiter.Quota.GatePaceVerdictTest do
  @moduledoc """
  `Gate.pace/6` and `Gate.paced_policy/1` (bd-clzkvp): the gate's own
  thresholds, evaluated through `Arbiter.Quota.Pace`, for one window — what the
  quota bars colour from. The table tests run the verdict and the gate's hold
  decision over the same inputs and require them to agree.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-09-23 12:00:00Z]
  @five_hours 18_000
  @seven_days 604_800

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.drop(prior, [:throttle_threshold, :weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp account(config), do: %ProviderAccount{provider: :claude, quota_config: config}
  defp paced(extra \\ %{}), do: account(Map.merge(%{"threshold_mode" => "paced"}, extra))
  defp ws(quota), do: %Workspace{id: "ws-pace", config: %{"quota" => quota}}

  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp snapshot(:primary, u, elapsed) do
    %Snapshot{
      provider: "claude",
      utilization: u,
      status: "allowed",
      reset_at: reset_after(elapsed, @five_hours),
      captured_at: @now,
      window_label: "5h",
      secondary_utilization: 0.0,
      secondary_status: "allowed",
      secondary_reset_at: reset_after(0.5, @seven_days),
      secondary_window_label: "7d"
    }
  end

  defp snapshot(:long, u, elapsed) do
    %Snapshot{
      provider: "claude",
      utilization: 0.0,
      status: "allowed",
      reset_at: reset_after(0.5, @five_hours),
      captured_at: @now,
      window_label: "5h",
      secondary_utilization: u,
      secondary_status: "allowed",
      secondary_reset_at: reset_after(elapsed, @seven_days),
      secondary_window_label: "7d"
    }
  end

  defp label(:primary), do: "5h"
  defp label(:long), do: "7d"
  defp seconds(:primary), do: @five_hours
  defp seconds(:long), do: @seven_days

  defp pace(policy, window, u, elapsed),
    do:
      Gate.pace(policy, window, label(window), u, reset_after(elapsed, seconds(window)),
        now: @now
      )

  defp gate_holds?(policy, window, u, elapsed) do
    case Gate.gating_window(snapshot(window, u, elapsed), policy, now: @now) do
      %{window: w, signal: :utilization} -> w == label(window)
      _ -> false
    end
  end

  describe "pace/6" do
    test "a paced account's 5h window" do
      assert %{verdict: :holding, ceiling: 0.35, mode: :paced} =
               pace(paced(), :primary, 0.36, 0.1)

      assert %{verdict: :approaching} = pace(paced(), :primary, 0.3, 0.1)
      assert %{verdict: :ok} = pace(paced(), :primary, 0.2, 0.1)
      assert %{verdict: :sampling} = pace(paced(), :primary, 0.1, 0.01)
    end

    test "a flat account is evaluated against its flat ceiling" do
      assert %{verdict: :approaching, ceiling: 0.85, mode: :flat} =
               pace(account(%{}), :primary, 0.8, 0.1)
    end

    test "composes min(account, workspace) like the gate" do
      policy = {paced(), ws(%{"throttle_threshold" => 0.4})}
      assert %{verdict: :holding, ceiling: 0.4, mode: :flat} = pace(policy, :primary, 0.45, 0.6)
    end

    test "the account's window_seconds sets the window length" do
      # 3.5 days to reset is half-way through a 7d window, 3/4 through a 14d one.
      policy = paced(%{"window_seconds" => %{"7d" => 2 * @seven_days}})
      assert %{verdict: :holding} = pace(paced(), :long, 0.6, 0.5)
      assert %{verdict: :ok, ceiling: 0.75} = pace(policy, :long, 0.6, 0.5)
    end

    test "a window with no known length falls back to the flat ceiling" do
      assert %{mode: :flat, ceiling: 0.85, elapsed: nil} =
               Gate.pace(paced(), :primary, "session", 0.5, reset_after(0.5, 3600), now: @now)
    end
  end

  describe "paced_policy/1 — the thresholds a paced account would hold at" do
    test "forces the account into paced mode, keeping its floors" do
      assert %{verdict: :ok, mode: :flat} = pace(account(%{}), :primary, 0.4, 0.1)

      assert %{verdict: :holding, ceiling: 0.35, mode: :paced} =
               pace(Gate.paced_policy(account(%{})), :primary, 0.4, 0.1)

      assert %{ceiling: 0.5} =
               pace(Gate.paced_policy(account(%{"paced_floor" => 0.5})), :primary, 0.4, 0.1)
    end

    test "keeps the workspace side, which may still tighten" do
      policy = Gate.paced_policy({account(%{}), ws(%{"throttle_threshold" => 0.3})})
      assert %{ceiling: 0.3, mode: :flat} = pace(policy, :primary, 0.1, 0.1)
    end

    test "works for a bare workspace or no policy at all" do
      assert %{mode: :paced, ceiling: 0.35} = pace(Gate.paced_policy(nil), :primary, 0.1, 0.1)
      assert %{mode: :paced, ceiling: 0.2} = pace(Gate.paced_policy(ws(%{})), :long, 0.1, 0.1)
    end
  end

  describe "the verdict and the gate agree over the same inputs" do
    @utilizations [0.0, 0.05, 0.1, 0.19, 0.2, 0.25, 0.29, 0.3, 0.34, 0.35, 0.36] ++
                    [0.45, 0.5, 0.55, 0.6, 0.75, 0.85, 0.9, 0.95, 0.99, 1.0]
    @elapsed [0.001, 0.05, 0.1, 0.2, 0.29, 0.3, 0.35, 0.5, 0.6, 0.9, 0.99]

    for window <- [:primary, :long],
        {name, policy} <- [
          paced: quote(do: paced()),
          flat: quote(do: account(%{})),
          loose_floor: quote(do: paced(%{"paced_floor" => 0.6, "weekly_paced_floor" => 0.4})),
          tightened_by_workspace:
            quote(do: {paced(), ws(%{"throttle_threshold" => 0.4, "weekly_threshold" => 0.3})})
        ] do
      test "#{window} window, #{name} policy: holding ⇔ the gate holds" do
        policy = unquote(policy)

        for u <- @utilizations, e <- @elapsed do
          holding? = pace(policy, unquote(window), u, e).verdict == :holding

          assert holding? == gate_holds?(policy, unquote(window), u, e),
                 "u=#{u} elapsed=#{e}: verdict holding?=#{holding?}"
        end
      end
    end

    test "regression: 7d at 35% used / 29% elapsed holds only where the gate does" do
      # Default weekly floor 0.20: 1.2x pace is over the paced ceiling.
      assert pace(paced(), :long, 0.35, 0.29).verdict == :holding
      assert gate_holds?(paced(), :long, 0.35, 0.29)

      # A 0.40 weekly floor: the gate dispatches, so the verdict must not hold.
      loose = paced(%{"weekly_paced_floor" => 0.4})
      assert pace(loose, :long, 0.35, 0.29).verdict == :approaching
      refute gate_holds?(loose, :long, 0.35, 0.29)
    end
  end
end
