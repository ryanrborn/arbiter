defmodule Arbiter.Quota.GateWeeklyTest do
  @moduledoc """
  Coverage for the 7-day (weekly) window on the dispatch quota gate (bd-1tuxv8).

  Before this, `Gate.over_cap?/2` read only the 5h window: a workspace sitting at
  `utilization_7d 0.76 / status_7d allowed_warning` dispatched straight through
  because `utilization_5h` was 0.23. These tests pin the two-window behaviour:
  a 7d utilization hold, a 7d reject, both `weekly_warning_policy` values, and
  the 5h window still holding on its own when the 7d window is fine.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  setup do
    prior = Application.get_env(:arbiter, :quota, [])

    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.merge(prior,
        on_exhaustion: :throttle,
        throttle_threshold: 0.85,
        overage_alert_usd: 50.0
      )
      |> Keyword.drop([:weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp ws(config \\ %{}), do: %Workspace{id: "ws-x", config: config}

  # A fresh snapshot: 5h window resets in an hour, captured just now.
  defp quota(attrs) do
    %AnthropicQuota{
      workspace_id: "ws-x",
      provider: "claude",
      captured_at: DateTime.utc_now(),
      reset_5h_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      status_5h: "allowed",
      utilization_5h: 0.23
    }
    |> struct(attrs)
  end

  describe "Snapshot.normalize/1 exposes both windows" do
    test "AnthropicQuota carries the 7d window alongside the 5h one" do
      reset_7d = DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)

      s =
        Snapshot.normalize(
          quota(%{
            utilization_7d: 0.76,
            status_7d: "allowed_warning",
            reset_7d_at: reset_7d,
            representative_claim: "seven_day"
          })
        )

      assert s.window_label == "5h"
      assert s.utilization == 0.23
      assert s.status == "allowed"

      assert s.secondary_window_label == "7d"
      assert s.secondary_utilization == 0.76
      assert s.secondary_status == "allowed_warning"
      assert s.secondary_reset_at == reset_7d
    end

    test "CodexQuota carries its weekly window as the secondary one" do
      s =
        Snapshot.normalize(%CodexQuota{
          workspace_id: "ws-x",
          provider: "codex",
          captured_at: DateTime.utc_now(),
          session_used_percent: 10.0,
          weekly_used_percent: 92.0
        })

      assert s.secondary_window_label == "weekly"
      assert_in_delta s.secondary_utilization, 0.92, 0.0001
      assert s.secondary_status == nil
    end
  end

  describe "7d utilization hold" do
    test "holds at/over the default 0.90 weekly threshold even when 5h is idle" do
      q = quota(%{utilization_7d: 0.91, status_7d: "allowed"})

      assert Gate.over_cap?(q, ws())
      assert %{window: "7d", signal: :utilization} = Gate.gating_window(q, ws())
      assert {:hold, %{window: "7d"}} = Gate.Throttle.check(nil, q, ws(), [])
    end

    test "allows below the weekly threshold" do
      q = quota(%{utilization_7d: 0.76, status_7d: "allowed"})

      refute Gate.over_cap?(q, ws())
      assert Gate.gating_window(q, ws()) == nil
      assert Gate.Throttle.check(nil, q, ws(), []) == :allow
    end

    test "honours a per-workspace quota.weekly_threshold override" do
      w = ws(%{"quota" => %{"weekly_threshold" => 0.7}})
      q = quota(%{utilization_7d: 0.76, status_7d: "allowed"})

      assert Gate.over_cap?(q, w)
      assert %{window: "7d", threshold: 0.7} = Gate.gating_window(q, w)
    end

    test "honours the global :weekly_threshold app-env" do
      Application.put_env(
        :arbiter,
        :quota,
        Keyword.put(Application.get_env(:arbiter, :quota, []), :weekly_threshold, 0.5)
      )

      q = quota(%{utilization_7d: 0.6, status_7d: "allowed"})
      assert Gate.over_cap?(q, ws())
    end

    test "the hold phrase names the 7d window and both numbers" do
      q = quota(%{utilization_7d: 0.91, status_7d: "allowed"})

      assert Gate.hold_phrase(q, ws()) == "7d quota 0.91 ≥ 0.90"
    end
  end

  describe "7d rejected always holds" do
    test "holds regardless of utilization or warning policy" do
      w = ws(%{"quota" => %{"weekly_warning_policy" => "ignore", "weekly_threshold" => 1.0}})
      q = quota(%{utilization_7d: 0.10, status_7d: "rejected"})

      assert Gate.over_cap?(q, w)
      assert %{window: "7d", signal: :status, status: "rejected"} = Gate.gating_window(q, w)
      assert {:hold, %{window: "7d", status: "rejected"}} = Gate.Throttle.check(nil, q, w, [])
      assert Gate.hold_phrase(q, w) == "7d quota exhausted (status=rejected)"
    end
  end

  describe "7d allowed_warning policy" do
    test "default policy is no effect — dispatch is allowed" do
      q = quota(%{utilization_7d: 0.76, status_7d: "allowed_warning"})

      refute Gate.over_cap?(q, ws())
      assert Gate.Throttle.check(nil, q, ws(), []) == :allow
    end

    test "explicit \"ignore\" policy is no effect" do
      w = ws(%{"quota" => %{"weekly_warning_policy" => "ignore"}})
      q = quota(%{utilization_7d: 0.76, status_7d: "allowed_warning"})

      refute Gate.over_cap?(q, w)
    end

    test "\"hold\" policy holds dispatch on the 7d warning" do
      w = ws(%{"quota" => %{"weekly_warning_policy" => "hold"}})
      q = quota(%{utilization_7d: 0.76, status_7d: "allowed_warning"})

      assert Gate.over_cap?(q, w)

      assert %{window: "7d", signal: :warning, status: "allowed_warning"} =
               Gate.gating_window(q, w)

      assert Gate.hold_phrase(q, w) == "7d quota allowed_warning (weekly_warning_policy: hold)"
    end

    test "the global app-env can set the warning policy" do
      Application.put_env(
        :arbiter,
        :quota,
        Keyword.put(Application.get_env(:arbiter, :quota, []), :weekly_warning_policy, :hold)
      )

      q = quota(%{utilization_7d: 0.76, status_7d: "allowed_warning"})
      assert Gate.over_cap?(q, ws())
    end
  end

  describe "the 5h window still gates on its own" do
    test "5h rejected holds and is reported as the 5h window" do
      q = quota(%{status_5h: "rejected", utilization_7d: 0.10, status_7d: "allowed"})

      assert %{window: "5h", signal: :status} = Gate.gating_window(q, ws())
      assert Gate.hold_phrase(q, ws()) == "quota exhausted"
    end

    test "5h utilization over the threshold holds while the 7d window is fine" do
      q = quota(%{utilization_5h: 0.9, utilization_7d: 0.10, status_7d: "allowed"})

      assert Gate.over_cap?(q, ws())
      assert %{window: "5h", signal: :utilization} = Gate.gating_window(q, ws())
      assert Gate.hold_phrase(q, ws()) =~ "quota near exhaustion"
    end

    test "a snapshot with no 7d data at all behaves exactly as before" do
      assert Gate.over_cap?(quota(%{}), ws()) == false
      assert Gate.over_cap?(quota(%{status_5h: "rejected"}), ws()) == true
    end

    # Reversed by bd-b7umwj. This used to assert that a stale snapshot failed
    # open on the 7d window too — which is precisely how the weekly stop was
    # defeated: the 5h window rolling (or the snapshot merely ageing out) threw
    # away a 7d reject that was still true. Staleness is now scoped per window,
    # so the 5h signals are dropped and the 7d hold survives. What lifts a 7d
    # hold is covered in `Arbiter.Quota.GateWeeklyStalenessTest`.
    test "a stale 5h window does not take the 7d hold down with it" do
      stale_5h =
        quota(%{
          reset_5h_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          utilization_7d: 0.99,
          status_7d: "rejected"
        })

      assert Gate.over_cap?(stale_5h, ws())
      assert %{window: "7d", signal: :status} = Gate.gating_window(stale_5h, ws())
      assert {:hold, %{window: "7d"}} = Gate.Throttle.check(nil, stale_5h, ws(), [])
    end

    test "a stale 5h window with a clean 7d window still fails open" do
      stale_5h =
        quota(%{
          reset_5h_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          status_5h: "rejected",
          utilization_7d: 0.10,
          status_7d: "allowed"
        })

      refute Gate.over_cap?(stale_5h, ws())
      assert Gate.Throttle.check(nil, stale_5h, ws(), []) == :allow
    end

    test "fails open on a nil snapshot" do
      assert Gate.gating_window(nil, ws()) == nil
      assert Gate.hold_phrase(nil, ws()) == nil
    end
  end

  describe "the board / Scheduler hold reason names the 7d window" do
    setup do
      {:ok, workspace} =
        Ash.create(Workspace, %{name: "weekly-board-ws", prefix: "wbw", config: %{}})

      %{workspace: workspace}
    end

    defp record_quota!(ws_id, attrs) do
      base = %{
        workspace_id: ws_id,
        provider: "claude",
        utilization_5h: 0.23,
        status_5h: "allowed",
        reset_5h_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      {:ok, q} =
        AnthropicQuota
        |> Ash.Changeset.for_create(:upsert, Map.merge(base, attrs))
        |> Ash.create()

      q
    end

    test "a 7d utilization hold reads as a 7d hold on the board", %{workspace: workspace} do
      record_quota!(workspace.id, %{
        utilization_7d: 0.91,
        status_7d: "allowed",
        reset_7d_at:
          DateTime.add(DateTime.utc_now(), 3 * 86_400, :second) |> DateTime.truncate(:second)
      })

      assert {:hold, "7d quota 0.91 ≥ 0.90"} = Arbiter.Board.Snapshot.quota_hold(workspace.id)

      plan =
        Arbiter.Board.Scheduler.plan(%{
          ready: [%{id: "bd-1", files: [], deps: []}],
          quota: Arbiter.Board.Snapshot.quota_hold(workspace.id),
          slots_free: 4
        })

      assert Enum.any?(plan.entries, &(&1.reason == "blocked — 7d quota 0.91 ≥ 0.90"))
    end

    test "a 5h hold still reads with the 5h wording", %{workspace: workspace} do
      record_quota!(workspace.id, %{
        utilization_5h: 0.9,
        utilization_7d: 0.1,
        status_7d: "allowed"
      })

      assert {:hold, phrase} = Arbiter.Board.Snapshot.quota_hold(workspace.id)
      assert phrase =~ "quota near exhaustion"
      refute phrase =~ "7d"
    end
  end

  describe "quota_get / arb quota expose the gating window" do
    test "names the 7d window when it is what holds dispatch" do
      {:ok, workspace} =
        Ash.create(Workspace, %{name: "weekly-serialize-ws", prefix: "wsw", config: %{}})

      record_quota!(workspace.id, %{
        utilization_7d: 0.91,
        status_7d: "allowed",
        reset_7d_at:
          DateTime.add(DateTime.utc_now(), 3 * 86_400, :second) |> DateTime.truncate(:second)
      })

      assert %{gating_window: "7d", gating_reason: "7d quota 0.91 ≥ 0.90"} =
               Arbiter.Quota.serialize(workspace.id)
    end

    test "gating_window is nil when nothing is gating" do
      {:ok, workspace} =
        Ash.create(Workspace, %{name: "weekly-serialize-ok", prefix: "wso", config: %{}})

      record_quota!(workspace.id, %{utilization_7d: 0.5, status_7d: "allowed"})

      assert %{gating_window: nil, gating_reason: nil} = Arbiter.Quota.serialize(workspace.id)
    end
  end

  describe "workspace config validation" do
    test "rejects an out-of-range weekly_threshold" do
      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "bad-weekly-thr",
                 prefix: "bwt",
                 config: %{"quota" => %{"weekly_threshold" => 1.5}}
               })

      assert Exception.message(error) =~ "quota.weekly_threshold must be a number in (0, 1]"
    end

    test "rejects an unknown weekly_warning_policy" do
      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "bad-weekly-pol",
                 prefix: "bwp",
                 config: %{"quota" => %{"weekly_warning_policy" => "shrug"}}
               })

      assert Exception.message(error) =~ "quota.weekly_warning_policy must be one of"
    end

    test "accepts the documented values" do
      assert {:ok, _ws} =
               Ash.create(Workspace, %{
                 name: "good-weekly",
                 prefix: "gw",
                 config: %{
                   "quota" => %{"weekly_threshold" => 0.8, "weekly_warning_policy" => "hold"}
                 }
               })
    end
  end
end
