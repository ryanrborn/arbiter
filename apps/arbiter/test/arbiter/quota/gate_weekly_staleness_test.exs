defmodule Arbiter.Quota.GateWeeklyStalenessTest do
  @moduledoc """
  Coverage for the sticky long-window hold (bd-b7umwj).

  bd-y0yup0 made a stale snapshot fail open so a fully-held fleet could still
  get one attempt through per staleness window and re-capture a real reading.
  That recovery works for the **primary** window, where the let-through attempt
  is refused by the provider and immediately re-captures `rejected`. It is a
  hole for the **long** window, where a hold happens at `allowed_warning`:
  Anthropic still accepts the request, so the let-through dispatch *succeeds*
  and runs a worker for hours against a budget the operator asked us to stop
  spending. The observed loop on 2026-09-11:

      7d held → no worker traffic → snapshot stale after 5 min → fail open →
      Autopilot dispatches → worker runs for hours at 96% → repeat

  So staleness is now scoped per window: the primary window still fails open on
  age (bd-y0yup0 intact), while a long-window hold is sticky — only a *fresh*
  snapshot showing it cleared, or the long window's own `reset_at` rolling,
  lifts it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @staleness_seconds 300

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.merge(prior,
        on_exhaustion: :throttle,
        throttle_threshold: 0.85,
        staleness_threshold_seconds: @staleness_seconds
      )
      |> Keyword.drop([:weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp ws(config \\ %{}), do: %Workspace{id: "ws-x", config: config}

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp ahead(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # The 2026-09-11 incident snapshot: 7d at 96% / allowed_warning against the
  # 0.90 default, 5h idle, captured well past the staleness threshold.
  defp aged_incident_quota(attrs \\ %{}) do
    %AnthropicQuota{
      workspace_id: "ws-x",
      provider: "claude",
      captured_at: ago(@staleness_seconds + 60),
      utilization_5h: 0.23,
      status_5h: "allowed",
      reset_5h_at: ahead(3600),
      utilization_7d: 0.96,
      status_7d: "allowed_warning",
      reset_7d_at: ahead(3 * 86_400)
    }
    |> struct(attrs)
  end

  describe "a stale 7d hold is sticky (bd-b7umwj)" do
    test "utilization over weekly_threshold still binds past the staleness threshold" do
      q = aged_incident_quota()

      assert Gate.stale?(q), "the snapshot must genuinely be age-stale for this test to mean anything"

      assert %{window: "7d", signal: :utilization, utilization: 0.96, threshold: 0.9} =
               Gate.gating_window(q, ws())

      assert Gate.over_cap?(q, ws())
      assert {:hold, %{window: "7d"}} = Gate.Throttle.check(nil, q, ws(), [])
    end

    test "a stale 7d `rejected` still binds" do
      q = aged_incident_quota(%{utilization_7d: 0.5, status_7d: "rejected"})

      assert %{window: "7d", signal: :status, status: "rejected"} = Gate.gating_window(q, ws())
    end

    test "a stale 7d allowed_warning still binds under weekly_warning_policy: hold" do
      q = aged_incident_quota(%{utilization_7d: 0.5, status_7d: "allowed_warning"})
      w = ws(%{"quota" => %{"weekly_warning_policy" => "hold"}})

      assert %{window: "7d", signal: :warning} = Gate.gating_window(q, w)
    end

    test "the 5h window rolling does not lift the 7d hold" do
      q = aged_incident_quota(%{reset_5h_at: ago(3600), status_5h: "rejected", utilization_5h: 0.99})

      # The 5h signals are dropped (that window has rolled and its numbers are
      # meaningless), but the 7d hold survives and is what is reported.
      assert %{window: "7d", signal: :utilization} = Gate.gating_window(q, ws())
    end

    test "a per-workspace weekly_threshold above the reading lifts it" do
      q = aged_incident_quota()
      assert Gate.gating_window(q, ws(%{"quota" => %{"weekly_threshold" => 0.99}})) == nil
    end
  end

  describe "what does lift a sticky 7d hold" do
    test "the 7d window's own reset_at passing" do
      q = aged_incident_quota(%{reset_7d_at: ago(60)})

      assert Gate.gating_window(q, ws()) == nil
      assert Gate.Throttle.check(nil, q, ws(), []) == :allow
    end

    test "a fresh snapshot showing the 7d window cleared" do
      fresh =
        aged_incident_quota(%{
          captured_at: DateTime.utc_now(),
          utilization_7d: 0.12,
          status_7d: "allowed"
        })

      assert Gate.gating_window(fresh, ws()) == nil
    end

    test "a snapshot older than the long window itself, with no 7d reset_at to trust" do
      # Bounded safety valve: with no `reset_7d_at` the sticky hold cannot key
      # on a rollover, so a reading older than a whole 7d window (which must
      # therefore have rolled at least once) stops binding.
      q = aged_incident_quota(%{reset_7d_at: nil, captured_at: ago(8 * 86_400)})

      assert Gate.gating_window(q, ws()) == nil
    end

    test "but a merely age-stale snapshot with no 7d reset_at still binds" do
      q = aged_incident_quota(%{reset_7d_at: nil})

      assert %{window: "7d"} = Gate.gating_window(q, ws())
    end
  end

  describe "the bd-y0yup0 5h recovery is untouched" do
    test "an age-stale 5h hold still fails open (one attempt per staleness window)" do
      q =
        aged_incident_quota(%{
          status_5h: "rejected",
          utilization_5h: 0.99,
          utilization_7d: 0.10,
          status_7d: "allowed"
        })

      assert Gate.gating_window(q, ws()) == nil
      assert Gate.Throttle.check(nil, q, ws(), []) == :allow
    end

    test "a 5h hold whose window already rolled still fails open" do
      q =
        aged_incident_quota(%{
          captured_at: DateTime.utc_now(),
          reset_5h_at: ago(3600),
          status_5h: "rejected",
          utilization_5h: 0.99,
          utilization_7d: 0.10,
          status_7d: "allowed"
        })

      assert Gate.gating_window(q, ws()) == nil
    end

    test "a fresh 5h hold is still held" do
      q =
        aged_incident_quota(%{
          captured_at: DateTime.utc_now(),
          status_5h: "rejected",
          utilization_7d: 0.10,
          status_7d: "allowed"
        })

      assert %{window: "5h", signal: :status} = Gate.gating_window(q, ws())
    end
  end

  describe "Codex's weekly window is sticky the same way" do
    test "an age-stale weekly utilization still binds while the session window fails open" do
      q = %CodexQuota{
        workspace_id: "ws-x",
        provider: "codex",
        captured_at: ago(@staleness_seconds + 60),
        session_used_percent: 99.0,
        limit_reached: true,
        session_reset_at: ahead(3600),
        weekly_used_percent: 96.0,
        weekly_reset_at: ahead(3 * 86_400)
      }

      assert %{window: "weekly", signal: :utilization} = Gate.gating_window(q, ws())
    end
  end

  describe "Gate.in_overage?/2 follows the same per-window staleness" do
    test "an age-stale 7d reject is still genuine past-plan usage" do
      q = aged_incident_quota(%{status_7d: "rejected"})
      assert Gate.in_overage?(q, ws())
    end

    test "an age-stale 5h reject still fails open" do
      q =
        aged_incident_quota(%{
          status_5h: "rejected",
          overage_status: "in_overage",
          utilization_7d: 0.10,
          status_7d: "allowed"
        })

      refute Gate.in_overage?(q, ws())
    end
  end

  describe "end to end: Autopilot's dispatch path stays held" do
    setup do
      prev = Application.get_env(:arbiter, :anthropic_proxy)

      Application.put_env(:arbiter, :anthropic_proxy,
        enabled: true,
        base_url: "http://127.0.0.1:4848"
      )

      on_exit(fn -> Application.put_env(:arbiter, :anthropic_proxy, prev) end)
      :ok
    end

    test "a dispatch against the stale 96%/allowed_warning snapshot is held, not spawned" do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "sticky-7d-#{System.unique_integer([:positive])}",
          prefix: "s7#{System.unique_integer([:positive])}",
          config: %{"quota" => %{"on_exhaustion" => "throttle"}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "burns-the-week", workspace_id: workspace.id})

      Ash.create!(AnthropicQuota, %{
        workspace_id: workspace.id,
        provider: "claude",
        captured_at: ago(@staleness_seconds + 60) |> DateTime.truncate(:second),
        utilization_5h: 0.23,
        status_5h: "allowed",
        reset_5h_at: ahead(3600) |> DateTime.truncate(:second),
        utilization_7d: 0.96,
        status_7d: "allowed_warning",
        reset_7d_at: ahead(3 * 86_400) |> DateTime.truncate(:second)
      })

      assert {:error, {:quota_held, held_id}} = Dispatch.dispatch(task.id, start_driver: false)
      assert held_id == task.id

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil

      assert %{gating_window: "7d", gating_reason: "7d quota 0.96 ≥ 0.90"} =
               Arbiter.Quota.serialize(workspace.id)
    end
  end
end
