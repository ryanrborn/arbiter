defmodule Arbiter.Quota.GatePacedTest do
  @moduledoc """
  Paced threshold mode on the dispatch quota gate (bd-2daof2).

  In `threshold_mode: "paced"` each window holds at
  `utilization >= max(floor, elapsed)` instead of a flat ceiling, where
  `elapsed` is how much of the window has gone by. Every test pins `opts[:now]`
  so the time-dependent math — and the staleness checks it sits beside — is
  deterministic.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-09-22 12:00:00Z]
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
  defp ws(quota), do: %Workspace{id: "ws-paced", config: %{"quota" => quota}}
  defp paced(extra \\ %{}), do: account(Map.merge(%{"threshold_mode" => "paced"}, extra))

  # `reset_at` such that `elapsed` of a window of `seconds` has gone by at @now.
  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  # A fresh Claude-shaped snapshot. Both windows default to "barely used,
  # half-way through" so a test only states the numbers it is about.
  defp snap(attrs) do
    struct(
      %Snapshot{
        provider: "claude",
        utilization: 0.01,
        status: "allowed",
        reset_at: reset_after(0.5, @five_hours),
        captured_at: @now,
        window_label: "5h",
        secondary_utilization: 0.01,
        secondary_status: "allowed",
        secondary_reset_at: reset_after(0.5, @seven_days),
        secondary_window_label: "7d"
      },
      attrs
    )
  end

  defp primary(u, elapsed, extra \\ %{}),
    do: snap(Map.merge(%{utilization: u, reset_at: reset_after(elapsed, @five_hours)}, extra))

  defp long(u, elapsed, extra \\ %{}) do
    snap(
      Map.merge(
        %{secondary_utilization: u, secondary_reset_at: reset_after(elapsed, @seven_days)},
        extra
      )
    )
  end

  defp gate(quota, policy), do: Gate.gating_window(quota, policy, now: @now)

  # A Codex-shaped snapshot: the primary slot is a session reset, not a
  # fixed-length window.
  defp codex(u) do
    snap(%{
      provider: "codex",
      status: nil,
      utilization: u,
      reset_at: DateTime.add(@now, 600, :second),
      window_label: "session",
      secondary_window_label: "weekly",
      secondary_status: nil
    })
  end

  defp create(quota, prefix) do
    Ash.create(Workspace, %{name: "paced-#{prefix}", prefix: prefix, config: %{"quota" => quota}})
  end

  describe "paced formula — primary window" do
    test "just after reset the floor binds" do
      refute gate(primary(0.34, 0.01), paced())

      assert %{window: "5h", signal: :utilization, mode: :paced, threshold: 0.35} =
               gate(primary(0.36, 0.01), paced())
    end

    test "mid-window holds only once utilization passes elapsed" do
      refute gate(primary(0.45, 0.5), paced())

      assert %{window: "5h", mode: :paced, threshold: t, elapsed: e} =
               gate(primary(0.55, 0.5), paced())

      assert_in_delta t, 0.5, 0.001
      assert_in_delta e, 0.5, 0.001
    end

    test "in the last minute of the window 0.99 does not hold" do
      q = snap(%{utilization: 0.99, reset_at: DateTime.add(@now, 30, :second)})
      refute gate(q, paced())
    end
  end

  describe "paced formula — long window" do
    test "just after reset the floor binds" do
      refute gate(long(0.19, 0.01), paced())

      assert %{window: "7d", signal: :utilization, mode: :paced, threshold: 0.2} =
               gate(long(0.21, 0.01), paced())
    end

    test "mid-window holds only once utilization passes elapsed" do
      refute gate(long(0.45, 0.5), paced())
      assert %{window: "7d", mode: :paced} = gate(long(0.55, 0.5), paced())
    end

    test "in the last minute of the window 0.99 does not hold" do
      q =
        snap(%{secondary_utilization: 0.99, secondary_reset_at: DateTime.add(@now, 30, :second)})

      refute gate(q, paced())
    end
  end

  describe "floors" do
    test "default primary floor is 0.35 and paced_floor overrides it" do
      assert %{threshold: 0.35} = gate(primary(0.4, 0.1), paced())
      refute gate(primary(0.4, 0.1), paced(%{"paced_floor" => 0.5}))
      assert %{threshold: 0.5} = gate(primary(0.5, 0.1), paced(%{"paced_floor" => "0.5"}))
    end

    test "default long floor is 0.20 and weekly_paced_floor overrides it" do
      assert %{threshold: 0.2} = gate(long(0.25, 0.1), paced())
      refute gate(long(0.25, 0.1), paced(%{"weekly_paced_floor" => 0.3}))
      assert %{threshold: 0.3} = gate(long(0.3, 0.1), paced(%{"weekly_paced_floor" => 0.3}))
    end
  end

  describe "modes are mutually exclusive" do
    test "paced ignores a configured weekly_threshold late in the window" do
      policy = paced(%{"weekly_threshold" => 0.5})
      refute gate(long(0.6, 0.9), policy)
    end

    test "paced ignores a configured throttle_threshold late in the window" do
      policy = paced(%{"throttle_threshold" => 0.5})
      refute gate(primary(0.6, 0.9), policy)
    end

    test "flat mode ignores the floors" do
      policy = account(%{"threshold_mode" => "flat", "paced_floor" => 0.1})
      refute gate(primary(0.5, 0.01), policy)

      policy = account(%{"weekly_paced_floor" => 0.95})
      assert %{window: "7d", threshold: 0.9} = binding = gate(long(0.91, 0.5), policy)
      refute Map.has_key?(binding, :mode)
    end

    test "flat is the default when threshold_mode is unset" do
      assert %{window: "5h", threshold: 0.85} = binding = gate(primary(0.86, 0.99), account(%{}))
      refute Map.has_key?(binding, :mode)
    end
  end

  describe "other rules are unchanged under paced mode" do
    test "primary past-plan status holds regardless of the paced threshold" do
      q = primary(0.01, 0.99, %{status: "rejected"})
      assert %{window: "5h", signal: :status} = gate(q, paced())
    end

    test "long-window rejected holds regardless of the paced threshold" do
      q = long(0.01, 0.99, %{secondary_status: "rejected"})
      assert %{window: "7d", signal: :status} = gate(q, paced())
    end

    test "weekly_warning_policy :hold still holds on allowed_warning" do
      q = long(0.01, 0.99, %{secondary_status: "allowed_warning"})

      assert %{window: "7d", signal: :warning} =
               gate(q, paced(%{"weekly_warning_policy" => "hold"}))
    end

    test "a stale primary window still fails open" do
      q = primary(0.9, 0.1, %{captured_at: DateTime.add(@now, -3600, :second)})
      refute gate(q, paced())
    end

    test "a stale long window still drops the long rules" do
      q =
        snap(%{secondary_utilization: 0.9, secondary_reset_at: DateTime.add(@now, -60, :second)})

      refute gate(q, paced())
    end
  end

  describe "account + workspace composition is min(account_now, workspace_now)" do
    test "account paced + workspace flat, flat is the min" do
      binding = gate(primary(0.45, 0.6), {paced(), ws(%{"throttle_threshold" => 0.4})})
      assert %{threshold: 0.4} = binding
      refute Map.has_key?(binding, :mode)
    end

    test "account paced + workspace flat, paced is the min" do
      assert %{mode: :paced, threshold: t} =
               gate(primary(0.55, 0.5), {paced(), ws(%{"throttle_threshold" => 0.7})})

      assert_in_delta t, 0.5, 0.001
    end

    test "account flat + workspace paced" do
      policy = {account(%{"throttle_threshold" => 0.6}), ws(%{"threshold_mode" => "paced"})}

      assert %{mode: :paced, threshold: 0.35} = gate(primary(0.4, 0.1), policy)
      # late in the window the account's flat 0.6 is the stricter side
      assert %{threshold: 0.6} = binding = gate(primary(0.65, 0.9), policy)
      refute Map.has_key?(binding, :mode)
    end

    test "a looser workspace floor does not loosen the account's" do
      policy = {paced(), ws(%{"threshold_mode" => "paced", "paced_floor" => 0.6})}
      assert %{threshold: 0.35} = gate(primary(0.4, 0.1), policy)
    end

    test "opts[:account] composes with a bare workspace" do
      opts = [now: @now, account: paced()]
      assert %{mode: :paced} = Gate.gating_window(primary(0.4, 0.1), ws(%{}), opts)
    end
  end

  describe "window_seconds/2" do
    test "built-in lengths" do
      assert Gate.window_seconds("5h") == 18_000
      assert Gate.window_seconds("7d") == 604_800
      assert Gate.window_seconds("weekly") == 604_800
      assert Gate.window_seconds("session") == nil
      assert Gate.window_seconds("used") == nil
      assert Gate.window_seconds(nil) == nil
    end

    test "the account's window_seconds wins" do
      a = account(%{"window_seconds" => %{"5h" => 36_000, "session" => "3600"}})
      assert Gate.window_seconds("5h", a) == 36_000
      assert Gate.window_seconds("session", a) == 3600
      assert Gate.window_seconds("7d", a) == 604_800
    end

    test "invalid account values fall back to the built-in table" do
      assert Gate.window_seconds("5h", account(%{"window_seconds" => %{"5h" => "nope"}})) ==
               18_000

      assert Gate.window_seconds("5h", account(%{"window_seconds" => %{"5h" => -5}})) == 18_000
      assert Gate.window_seconds("5h", account(%{"window_seconds" => "garbage"})) == 18_000
    end
  end

  describe "window-length resolution in the gate" do
    test "an account override changes the effective paced threshold" do
      # 3.5 days to reset: half-way through a 7d window, 3/4 through a 14d one
      q = snap(%{secondary_utilization: 0.6, secondary_reset_at: reset_after(0.5, @seven_days)})

      assert %{window: "7d", mode: :paced} = gate(q, paced())
      refute gate(q, paced(%{"window_seconds" => %{"7d" => 2 * @seven_days}}))
    end

    test "Codex session falls back to the flat threshold" do
      q = codex(0.5)
      refute gate(q, paced())
      assert %{window: "session", threshold: 0.85} = binding = gate(codex(0.86), paced())
      refute Map.has_key?(binding, :mode)
    end

    test "Codex session is paced once the account names its length" do
      policy = paced(%{"window_seconds" => %{"session" => 3600}})
      # 50 minutes left of a one-hour session: 17% elapsed, so the 0.35 floor binds
      q = %{codex(0.5) | reset_at: DateTime.add(@now, 3000, :second)}
      assert %{window: "session", mode: :paced, threshold: 0.35} = gate(q, policy)
    end

    test "Gemini CLI `used` falls back to the flat threshold" do
      q = %Snapshot{
        provider: "gemini_cli",
        utilization: 0.5,
        reset_at: DateTime.add(@now, 3600, :second),
        captured_at: @now,
        window_label: "used"
      }

      refute gate(q, paced())
      assert %{window: "used", threshold: 0.85} = gate(%{q | utilization: 0.86}, paced())
    end

    test "an Antigravity 5h / weekly snapshot is paced" do
      q =
        snap(%{
          provider: "antigravity",
          status: nil,
          secondary_status: nil,
          secondary_window_label: "weekly"
        })

      assert %{window: "5h", mode: :paced} =
               gate(%{q | utilization: 0.4, reset_at: reset_after(0.1, @five_hours)}, paced())

      assert %{window: "weekly", mode: :paced} =
               gate(
                 %{
                   q
                   | secondary_utilization: 0.3,
                     secondary_reset_at: reset_after(0.1, @seven_days)
                 },
                 paced()
               )
    end

    test "a nil reset_at falls back to the flat threshold" do
      refute gate(snap(%{utilization: 0.5, reset_at: nil}), paced())
    end

    test "a workspace window_seconds is ignored" do
      policy = ws(%{"threshold_mode" => "paced", "window_seconds" => %{"session" => 3600}})
      refute gate(codex(0.5), policy)
    end
  end

  describe "account quota_config parsing" do
    test "an invalid threshold_mode falls back to flat" do
      policy = account(%{"threshold_mode" => "turbo"})
      assert %{threshold: 0.85} = binding = gate(primary(0.86, 0.99), policy)
      refute Map.has_key?(binding, :mode)
    end

    test "an invalid floor falls back to the default" do
      assert %{threshold: 0.35} = gate(primary(0.4, 0.01), paced(%{"paced_floor" => "abc"}))
      assert %{threshold: 0.2} = gate(long(0.25, 0.01), paced(%{"weekly_paced_floor" => 1.5}))
    end
  end

  describe "hold_phrase/3" do
    test "long window names the paced line and elapsed" do
      q = long(0.62, 0.55)
      assert Gate.hold_phrase(q, paced(), now: @now) == "7d quota 0.62 ≥ paced 0.55 (55% elapsed)"
    end

    test "primary window says it is ahead of pace" do
      q = primary(0.4, 0.3)

      assert Gate.hold_phrase(q, paced(), now: @now) ==
               "quota ahead of pace (40% of window used, paced ceiling 35%, 30% elapsed)"
    end

    test "flat phrases are unchanged" do
      assert Gate.hold_phrase(primary(0.9, 0.5), account(%{}), now: @now) ==
               "quota near exhaustion (90% of window used, ceiling 85%)"

      assert Gate.hold_phrase(long(0.91, 0.5), account(%{}), now: @now) == "7d quota 0.91 ≥ 0.90"
    end
  end

  describe "production path: a persisted paced account (real clock)" do
    # The dispatcher and the board both resolve the linked account from the
    # DB and hand it to the gate; this drives that path with a round-tripped
    # `quota_config` rather than a hand-built struct.
    setup do
      n = System.unique_integer([:positive])
      ws = Ash.create!(Workspace, %{name: "paced-prod-#{n}", prefix: "ppr#{n}"})
      %{ws: ws, n: n}
    end

    defp linked_account!(ws, n, quota_config) do
      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "paced-#{n}-#{System.unique_integer([:positive])}",
          label: "paced",
          quota_config: quota_config
        })

      Ash.create!(Arbiter.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

      # 40% used, 30 minutes into the 5h window: under a flat 0.85, over the
      # paced 0.35 floor.
      quota =
        Ash.create!(Arbiter.Quota.AnthropicQuota, %{
          provider_account_id: account.id,
          provider: "claude",
          utilization_5h: 0.40,
          status_5h: "allowed",
          reset_5h_at: DateTime.add(DateTime.utc_now(), 16_200, :second),
          captured_at: DateTime.utc_now()
        })

      {account, quota}
    end

    test "the board and Throttle.check hold a paced account ahead of pace", %{ws: ws, n: n} do
      {account, quota} = linked_account!(ws, n, %{"threshold_mode" => "paced"})

      assert {:hold, _} = Arbiter.Board.Snapshot.quota_hold(ws.id)

      assert {:hold, %{mode: :paced, window: "5h", threshold: 0.35, phrase: phrase}} =
               Gate.Throttle.check(nil, quota, ws, account: account)

      assert phrase =~ "quota ahead of pace (40% of window used, paced ceiling 35%, 10% elapsed)"
    end

    test "the same reading dispatches under the default flat mode", %{ws: ws, n: n} do
      {account, quota} = linked_account!(ws, n, %{})

      assert Arbiter.Board.Snapshot.quota_hold(ws.id) == :ok
      assert Gate.Throttle.check(nil, quota, ws, account: account) == :allow
    end
  end

  describe "workspace config validation" do
    test "accepts the documented values" do
      assert {:ok, _} =
               create(
                 %{
                   "threshold_mode" => "paced",
                   "paced_floor" => 0.4,
                   "weekly_paced_floor" => "1"
                 },
                 "pa"
               )

      assert {:ok, _} = create(%{"threshold_mode" => "flat"}, "pb")
    end

    test "rejects an unknown threshold_mode" do
      assert {:error, error} = create(%{"threshold_mode" => "turbo"}, "pc")
      assert Exception.message(error) =~ "quota.threshold_mode must be one of flat, paced"
    end

    test "rejects out-of-range floors" do
      for {key, value, prefix} <- [
            {"paced_floor", 0, "pd"},
            {"paced_floor", 1.5, "pe"},
            {"weekly_paced_floor", "abc", "pf"},
            {"weekly_paced_floor", -0.1, "pg"}
          ] do
        assert {:error, error} = create(%{key => value}, prefix)
        assert Exception.message(error) =~ "quota.#{key} must be a number in (0, 1]"
      end
    end
  end
end
