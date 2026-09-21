defmodule Arbiter.Workflows.QuotaGate do
  @moduledoc """
  Swappable interface for the Conductor's quota gate.

  The Conductor calls `c:quota_headroom/2` on every drain cycle and folds the
  result into the effective concurrency cap:

      effective_cap = min(workspace_max, system_max, quota_headroom)

  Returning `:unlimited` imposes no quota-based restriction — the hardware caps
  (`workspace_max` / `system_max`) apply as-is. Returning `0` holds all
  dispatch until the next cycle. A positive integer `n` limits dispatch to at
  most `n` concurrent members from the quota side (reserved for smarter
  throttles in later work; the simple `Default` only ever returns `:unlimited`
  or `0`).

  ## Breaking change: the callback is keyed by the provider account (P7)

  Until P7 (`docs/provider-account-design.md` §4.2, §5 row 22) the callback
  took a `workspace_id`. It now takes a **`provider_account_id`**, with the
  asking workspace passed alongside as context in `opts`:

      # before
      def quota_headroom(workspace_id)

      # after
      def quota_headroom(provider_account_id, opts)

  The key had to move because the thing the provider meters is the account,
  not the workspace. Three workspaces sharing one Anthropic account share one
  budget; keying the hold by workspace meant `default` could hold on an
  exhausted account while `vstim` kept dispatching straight into it. The
  snapshot the gate reads has been the account's since P5 — P7 makes the
  callback say so.

  There is deliberately **no opt-in flag** for this (§4.4): an account-wide
  *ceiling* can cut throughput below what an operator intended, but an
  account-wide *hold* can only ever stop dispatch against a budget that is
  already exhausted.

  ### What a custom implementation must change

    * Take two arguments. `opts` carries `:workspace_id` / `:workspace` (the
      workspace whose Conductor is asking — use it for per-workspace policy,
      never as the quota key) and `:provider` (the resolved quota provider).
    * Read the snapshot with `Arbiter.Quota.latest_for_provider/2`, which
      takes the account id. `Arbiter.Quota.latest_for_workspace/2` still
      exists for non-gate callers but is no longer the gate path.
    * Resolve thresholds through `Arbiter.Quota.Gate.threshold/1` and friends
      with a `{account, workspace}` policy, so a workspace can only *tighten*
      the account's number (§4.2).

  ## Swapping the implementation

  Pass `:quota_gate` to `Conductor.kickoff/2` or configure at the application
  level:

      config :arbiter, :conductor_quota_gate, MyCustomQuotaGate

  Any module that implements this behaviour can replace `Default` without
  changing the Conductor.
  """

  @doc """
  Return the number of dispatch slots the quota permits for
  `provider_account_id`, or `:unlimited` when quota imposes no constraint
  this cycle.

  * `:unlimited` — no quota-based restriction.
  * `0` — quota exhausted or status is not "allowed"; hold all dispatch.
  * `n > 0` — at most `n` concurrent slots from quota's perspective.

  `opts` is context, never the key:

    * `:workspace_id` — the workspace whose Conductor is asking. Supplies the
      `:continue`-mode check and the workspace half of the threshold policy.
    * `:workspace` — the already-loaded `Arbiter.Tasks.Workspace`, when the
      caller has one (saves the `Ash.get`).
    * `:provider` — the quota provider this cycle's dispatches will run on.
      Defaults to the workspace's default provider.

  A `nil` account id fails open (`:unlimited`), the same way a missing
  snapshot always has.
  """
  @callback quota_headroom(provider_account_id :: String.t() | nil, opts :: keyword()) ::
              non_neg_integer() | :unlimited

  defmodule Default do
    @moduledoc """
    Simple threshold quota gate (C4 of #482).

    Reads the latest captured quota snapshot for the **provider account** the
    asking workspace is metered under, on that workspace's **default agent
    provider** (bd-2mpo3f, resolved via `Arbiter.Quota.default_provider/1`) —
    `AnthropicQuota` for Claude, `CodexQuota` for Codex, `GoogleQuota` for
    Gemini CLI — and defers the over-cap decision to
    `Arbiter.Quota.Gate.over_cap?/2`, the same status/utilization/threshold/
    staleness check the board's `Arbiter.Board.Snapshot.quota_hold/1` and the
    `dispatch/2` quota seam both use (bd-5j6nmn) — one shared implementation
    answering "is this account+provider over its quota cap" everywhere it's
    asked.

    Because the key is the account (P7), a hold covers **every** workspace
    metered under it. That is the correctness fix: two workspaces on one
    exhausted account can no longer disagree about whether the budget is gone.

    A per-task provider override (`agent_type:` on `dispatch/2`) is not visible
    here — this clamp is a per-workspace concurrency cap, and the authoritative
    per-dispatch decision is `Arbiter.Quota.Gate` at the `dispatch/2` seam.

    Returns `:unlimited` when `over_cap?/2` is false (the quota is fine, the
    snapshot is stale, or no snapshot has been captured yet — assume OK).
    Returns `0` (hold) when `over_cap?/2` is true.

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

    That check is per *workspace*, not per account, and stays that way:
    `on_exhaustion` is how a workspace says what to do when the budget runs
    out, not a claim about whose budget it is.

    The throttle threshold is `Arbiter.Quota.Gate.threshold/1`, resolved
    `min(account, workspace)` (§4.2) — the account's
    `quota_config["throttle_threshold"]` is the floor and the workspace's
    `config["quota"]["throttle_threshold"]` may only tighten it, falling back
    to the global `:arbiter, :quota, :throttle_threshold` and then `0.85`.
    A `nil` account id reads as no-snapshot (returns `:unlimited`).
    """

    @behaviour Arbiter.Workflows.QuotaGate

    alias Arbiter.Accounts.Resolver
    alias Arbiter.Quota
    alias Arbiter.Quota.Gate

    @impl true
    def quota_headroom(provider_account_id, opts \\ []) do
      workspace = resolve_workspace(opts)

      if Quota.continue_mode?(workspace) do
        :unlimited
      else
        throttle_headroom(account_id(provider_account_id), workspace, opts)
      end
    end

    defp throttle_headroom(nil, _workspace, _opts), do: :unlimited

    defp throttle_headroom(account_id, workspace, opts) do
      provider = Keyword.get(opts, :provider) || default_provider(workspace)
      snapshot = Quota.latest_for_provider(account_id, provider)
      account = safe_account(account_id)

      if Gate.over_cap?(snapshot, {account, workspace}), do: 0, else: :unlimited
    end

    defp account_id(id) when is_binary(id) and id != "", do: id
    defp account_id(_), do: nil

    defp default_provider(nil), do: :claude
    defp default_provider(workspace), do: Quota.default_provider(workspace)

    defp resolve_workspace(opts) do
      case Keyword.get(opts, :workspace) do
        %Arbiter.Tasks.Workspace{} = ws -> ws
        _ -> opts |> Keyword.get(:workspace_id) |> safe_workspace()
      end
    end

    defp safe_workspace(ws_id) when is_binary(ws_id) and ws_id != "" do
      case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
        {:ok, ws} -> ws
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end

    defp safe_workspace(_), do: nil

    defp safe_account(account_id) do
      Resolver.get(account_id)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
