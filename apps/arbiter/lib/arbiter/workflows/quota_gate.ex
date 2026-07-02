defmodule Arbiter.Workflows.QuotaGate do
  @moduledoc """
  Swappable interface for the Conductor's quota gate.

  The Conductor calls `c:quota_headroom/1` on every drain cycle and folds the
  result into the effective concurrency cap:

      effective_cap = min(workspace_max, system_max, quota_headroom)

  Returning `:unlimited` imposes no quota-based restriction — the hardware caps
  (`workspace_max` / `system_max`) apply as-is. Returning `0` holds all
  dispatch until the next cycle. A positive integer `n` limits dispatch to at
  most `n` concurrent members from the quota side (reserved for smarter
  throttles in later work; the simple `Default` only ever returns `:unlimited`
  or `0`).

  ## Swapping the implementation

  Pass `:quota_gate` to `Conductor.kickoff/2` or configure at the application
  level:

      config :arbiter, :conductor_quota_gate, MyCustomQuotaGate

  Any module that implements this behaviour can replace `Default` without
  changing the Conductor.
  """

  @doc """
  Return the number of dispatch slots the quota permits, or `:unlimited` when
  quota imposes no constraint this cycle.

  * `:unlimited` — no quota-based restriction.
  * `0` — quota exhausted or status is not "allowed"; hold all dispatch.
  * `n > 0` — at most `n` concurrent slots from quota's perspective.
  """
  @callback quota_headroom(workspace_id :: String.t() | nil) ::
              non_neg_integer() | :unlimited

  defmodule Default do
    @moduledoc """
    Simple threshold quota gate (C4 of #482).

    Reads the latest captured Anthropic quota snapshot for the workspace from
    the DB (written by the proxy on every `/v1/messages` response) and applies
    a two-condition hold:

      1. `status_5h` is not `nil` and not `"allowed"`.
      2. `utilization_5h` is not `nil` and exceeds the configured ceiling.

    Returns `:unlimited` when either condition does not hold (either the quota
    is fine, or no snapshot has been captured yet — assume OK). Returns `0`
    (hold) when either condition fires.

    ## `:continue` workspaces defer to the dispatch seam (bd-7cd38f)

    A workspace configured `quota.on_exhaustion == :continue` must dispatch
    *past* the cap (paid overage), not stop at it. The Conductor's cap-clamp
    runs before `Arbiter.Worker.Dispatch.dispatch/2`, so if it held graph
    dispatch at the ceiling the `:continue` contract would be silently
    violated — dispatch would never reach the new quota seam that records the
    overage. To keep `dispatch/2` the single choke point, this gate returns
    `:unlimited` for `:continue` workspaces and defers the entire quota decision
    (allow / overage) to that seam. `:throttle` workspaces keep the cap-clamp
    (equivalent throttling: work is delayed, retried each drain cycle in
    graph-ready order, never dropped). Reviewer round 1, finding 1.

    Configure the utilisation ceiling via:

        config :arbiter, :conductor_quota_ceiling, 0.85

    Default ceiling is `0.85` (85% of the 5-hour window). A `nil` workspace
    id reads as no-snapshot (returns `:unlimited`).
    """

    @behaviour Arbiter.Workflows.QuotaGate

    @default_ceiling 0.85

    @impl true
    def quota_headroom(workspace_id) do
      ws_id = to_string(workspace_id || "")

      cond do
        # :continue mode — never clamp here; the dispatch/2 quota seam owns the
        # allow/overage decision so :continue graph work proceeds past the cap.
        continue_workspace?(ws_id) ->
          :unlimited

        true ->
          throttle_headroom(ws_id)
      end
    end

    defp throttle_headroom(ws_id) do
      ceiling = Application.get_env(:arbiter, :conductor_quota_ceiling, @default_ceiling)

      case Arbiter.Quota.latest(ws_id) do
        nil ->
          :unlimited

        quota ->
          status_ok? = quota.status_5h in [nil, "allowed"]
          utilization_ok? = is_nil(quota.utilization_5h) or quota.utilization_5h <= ceiling

          if status_ok? and utilization_ok?, do: :unlimited, else: 0
      end
    end

    # Whether the workspace's resolved quota mode is :continue. Best-effort: any
    # load failure falls through to :throttle (the safe, cap-clamping default).
    defp continue_workspace?(""), do: false

    defp continue_workspace?(ws_id) do
      case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
        {:ok, ws} -> Arbiter.Tasks.Workspace.quota_on_exhaustion(ws) == :continue
        _ -> false
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end
end
