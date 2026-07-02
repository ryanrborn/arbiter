defmodule Arbiter.Quota.GateTest do
  @moduledoc """
  Unit coverage for the quota-aware dispatch gate config + resolution (bd-7cd38f):
  precedence of `on_exhaustion` / `overage_alert_usd`, workspace config
  validation, and the `Throttle` / `Continue` gate decisions incl. fail-open.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Tasks.Workspace

  # Build an in-memory Workspace struct with the given config (no DB needed for
  # the pure resolver helpers).
  defp ws(config), do: %Workspace{id: "ws-x", config: config}

  defp quota(attrs) do
    %AnthropicQuota{
      workspace_id: "ws-x",
      provider: "claude",
      captured_at: DateTime.utc_now()
    }
    |> struct(attrs)
  end

  describe "Workspace.quota_on_exhaustion/1 precedence" do
    test "per-workspace override beats the global default" do
      # global default is :throttle (config.exs); workspace says continue
      assert Workspace.quota_on_exhaustion(ws(%{"quota" => %{"on_exhaustion" => "continue"}})) ==
               :continue
    end

    test "falls back to the global default when unset" do
      Application.put_env(:arbiter, :quota, on_exhaustion: :continue)
      on_exit(fn -> restore_quota_env() end)

      assert Workspace.quota_on_exhaustion(ws(%{})) == :continue
    end

    test "falls back to hardcoded :throttle when global is unset" do
      Application.put_env(:arbiter, :quota, [])
      on_exit(fn -> restore_quota_env() end)

      assert Workspace.quota_on_exhaustion(ws(%{})) == :throttle
      assert Workspace.quota_on_exhaustion(nil) == :throttle
    end
  end

  describe "Workspace.quota_overage_alert_usd/1 precedence" do
    test "per-workspace override beats global" do
      Application.put_env(:arbiter, :quota, overage_alert_usd: 100.0)
      on_exit(fn -> restore_quota_env() end)

      assert Workspace.quota_overage_alert_usd(ws(%{"quota" => %{"overage_alert_usd" => 25}})) ==
               25.0
    end

    test "accepts JSON string form" do
      assert Workspace.quota_overage_alert_usd(ws(%{"quota" => %{"overage_alert_usd" => "12.5"}})) ==
               12.5
    end

    test "falls back to global default, then nil" do
      Application.put_env(:arbiter, :quota, overage_alert_usd: 75.0)
      on_exit(fn -> restore_quota_env() end)
      assert Workspace.quota_overage_alert_usd(ws(%{})) == 75.0

      Application.put_env(:arbiter, :quota, [])
      assert Workspace.quota_overage_alert_usd(ws(%{})) == nil
    end
  end

  describe "Quota.gate_for_workspace/1" do
    test "resolves :throttle → Throttle, :continue → Continue" do
      assert Quota.gate_for_workspace(ws(%{"quota" => %{"on_exhaustion" => "throttle"}})) ==
               Arbiter.Quota.Gate.Throttle

      assert Quota.gate_for_workspace(ws(%{"quota" => %{"on_exhaustion" => "continue"}})) ==
               Arbiter.Quota.Gate.Continue
    end

    test ":gate app-env is a hard override (kill switch)" do
      Application.put_env(:arbiter, :quota, gate: Arbiter.Quota.Gate.Continue)
      on_exit(fn -> restore_quota_env() end)

      # Even a throttle workspace resolves to the overridden module.
      assert Quota.gate_for_workspace(ws(%{"quota" => %{"on_exhaustion" => "throttle"}})) ==
               Arbiter.Quota.Gate.Continue
    end
  end

  describe "config validation" do
    test "rejects an unknown on_exhaustion mode" do
      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "bad-mode",
                 prefix: "bm",
                 config: %{"quota" => %{"on_exhaustion" => "pause"}}
               })

      assert Exception.message(error) =~ "quota.on_exhaustion must be one of"
    end

    test "rejects a non-positive overage_alert_usd" do
      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "bad-usd",
                 prefix: "bu",
                 config: %{"quota" => %{"on_exhaustion" => "continue", "overage_alert_usd" => -5}}
               })

      assert Exception.message(error) =~ "quota.overage_alert_usd must be a positive number"
    end

    test "rejects an out-of-range throttle_threshold" do
      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "bad-thr",
                 prefix: "bt",
                 config: %{"quota" => %{"throttle_threshold" => 1.5}}
               })

      assert Exception.message(error) =~ "quota.throttle_threshold must be a number in (0, 1]"
    end

    test "accepts a valid quota block" do
      assert {:ok, _ws} =
               Ash.create(Workspace, %{
                 name: "good-quota",
                 prefix: "gq",
                 config: %{
                   "quota" => %{"on_exhaustion" => "continue", "overage_alert_usd" => 20}
                 }
               })
    end
  end

  describe "Gate.Throttle.check/4" do
    test "fails open on a nil snapshot" do
      assert Gate.Throttle.check(nil, nil, ws(%{}), []) == :allow
    end

    test "holds when status_5h is not allowed" do
      assert {:hold, _reason} =
               Gate.Throttle.check(nil, quota(%{status_5h: "rejected"}), ws(%{}), [])
    end

    test "holds when utilization is at/over the threshold" do
      # default threshold 0.85
      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 quota(%{status_5h: "allowed", utilization_5h: 0.9}),
                 ws(%{}),
                 []
               )
    end

    test "allows when under the cap" do
      assert Gate.Throttle.check(
               nil,
               quota(%{status_5h: "allowed", utilization_5h: 0.2}),
               ws(%{}),
               []
             ) == :allow
    end

    test "respects a per-workspace threshold override" do
      w = ws(%{"quota" => %{"throttle_threshold" => 0.5}})

      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 quota(%{status_5h: "allowed", utilization_5h: 0.6}),
                 w,
                 []
               )
    end
  end

  describe "Gate.Continue.check/4" do
    test "fails open on a nil snapshot" do
      assert Gate.Continue.check(nil, nil, ws(%{}), []) == :allow
    end

    test "allows (no overage tag) when under the cap" do
      assert Gate.Continue.check(
               nil,
               quota(%{status_5h: "allowed", utilization_5h: 0.1, overage_status: nil}),
               ws(%{}),
               []
             ) == :allow
    end

    test "tags overage when in_overage" do
      assert {:overage, spend} =
               Gate.Continue.check(
                 nil,
                 quota(%{status_5h: "allowed", overage_status: "in_overage"}),
                 ws(%{}),
                 []
               )

      assert is_float(spend)
    end
  end

  defp restore_quota_env do
    Application.put_env(:arbiter, :quota,
      on_exhaustion: :throttle,
      throttle_threshold: 0.85,
      overage_alert_usd: 50.0
    )
  end
end
