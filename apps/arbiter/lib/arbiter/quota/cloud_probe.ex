defmodule Arbiter.Quota.CloudProbe do
  @moduledoc """
  Periodic refresh probe for the *non-Anthropic* quota providers — Codex,
  Gemini CLI, and Antigravity (bd-ajh7bd).

  ## Motivation

  Claude quota stays fresh on its own timer: this same GenServer also polls
  Anthropic's `/api/oauth/usage` (bd-b0zody, bd-atyrrq — see
  `capture_oauth_usage_for_group/2` below), so an idle fleet's snapshot never
  goes stale for lack of proxied traffic. Codex / Gemini CLI / Antigravity
  have no such passive signal either — their figures only ever came from a
  *live fetch on each `GET /api/quota` call*, and (before this change)
  Gemini/Antigravity were never persisted at all. So the web dashboard, which
  reads only the persisted quota tables, could never show them, and there was
  no history to audit.

  This GenServer closes that gap. On a recurring timer it refreshes each
  provider for every workspace, which upserts the snapshot and broadcasts
  `{:quota_updated, ws_id, view}` on the `"quota:<ws_id>"` PubSub topic — the
  same topic the LiveView `:quota` hook subscribes to. The prober becomes the
  *only* place that calls out to OpenAI/Google, so `GET /api/quota` and
  `arb quota` are pure DB reads (no request-time latency or rate-limit risk).

  ## What a refresh does per workspace

    * `Arbiter.Quota.Codex.fetch/2` — one GET to OpenAI's usage endpoint using
      the `codex` CLI's stored token; upserts `CodexQuota` + broadcasts.
    * `Arbiter.Quota.CloudCode.refresh/3` for `:gemini` and `:antigravity` — a
      direct Cloud Code Assist call using the Gemini CLI's stored token; upserts
      `GoogleQuota` + broadcasts.
    * `Arbiter.Quota.capture_oauth_usage_for_group/2` — Anthropic's
      `/api/oauth/usage` source (per-model weekly + `extra_usage` overage,
      bd-8tpha6, *and* the primary gate columns since bd-b0zody). This is the
      only thing that keeps Claude's snapshot current for a fleet making no
      proxied traffic, so it is no longer merely a garnish riding along
      (best-effort; its own 429 cooldown protects it). This endpoint is
      account-wide, and this install has exactly one account credential — the
      operator's `~/.claude/.credentials.json` — so it is fetched **once per
      cycle for every workspace**, not fanned out per workspace like the rest
      of this module. Its 5 min cadence is the endpoint's own budget; the gate
      absorbs a missed poll by trusting a polled row for 600s
      (`Arbiter.Quota.Gate.staleness_threshold_seconds/1`) rather than by
      polling harder.

      bd-5xuneh de-duplicated this call by grouping workspaces on
      `ConfigDir.oauth_token/1` and passing that token explicitly, on the
      theory that workspaces sharing a token could safely share one fetch.
      bd-4fbpto found that theory backwards: a workspace's `worker_env` token
      is scope/rate-limited for this endpoint (empirically confirmed — see the
      bd-4fbpto writeup for the status codes) while the operator's
      credentials-file token succeeds, so passing the workspace token here was
      why every poll silently failed once bd-7cvh8z removed the proxy's
      header-capture fallback. This module no longer resolves or passes a
      per-workspace token at all: `Arbiter.Quota.OAuthUsage.fetch/1`'s own
      default (read `.credentials.json`) is always used.

  The other three providers each degrade to a no-op (no row written, no
  broadcast) when their CLI isn't authenticated on this host, so a logged-out
  provider simply never appears rather than wiping the last good reading.
  Their credentials are host-global, so the figures written under each
  workspace id are identical — we still fan those three out per workspace so
  every workspace's dashboard is fed.

  ## Cadence

  A single `interval_ms` (default 5 min). These are cheap metadata calls that
  spend no model quota, so there's no active/idle split or reset-boundary
  gating — a plain heartbeat is enough.

  ## Configuration

  Via `config :arbiter, :cloud_quota_probe`:

    * `:enabled`     — master switch (default `true`; `false` in test).
    * `:interval_ms` — refresh interval (default 300 000).

  ## Test injection

  Pass `:refresh_fun` — a `fn(workspace_id :: String.t()) :: any()` — to
  `start_link/1` to replace the default three-provider refresh. Tests pass a
  stub so there is no dependency on real CLIs or HTTP.

  Pass `:oauth_opts` — a keyword list forwarded verbatim to
  `Arbiter.Quota.capture_oauth_usage_for_group/2` (and from there to
  `Arbiter.Quota.OAuthUsage.fetch/1`) — to point the account-wide poll at a
  fixture `:source_dir` instead of the real `~/.claude/.credentials.json`, or
  to inject a `:base_url` / `:plug`. Defaults to `[]`.
  """

  use GenServer
  require Logger

  alias Arbiter.Messages.CoordinatorNotifier

  @default_interval_ms 300_000

  # Consecutive `/api/oauth/usage` poll failures before escalating to the
  # coordinator mailbox (bd-4fbpto) — three missed cycles (~15 min at the
  # default cadence) is long enough that a single transient 429 doesn't page
  # anyone, but short enough that a real outage doesn't sit unnoticed for
  # hours the way this one did.
  @oauth_failure_escalation_threshold 3

  defmodule State do
    @moduledoc false
    defstruct [
      :interval_ms,
      :refresh_fun,
      :enabled,
      :oauth_opts,
      probe_count: 0,
      oauth_consecutive_failures: 0
    ]
  end

  # ---- public API --------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Force an immediate refresh cycle and wait for it to be dispatched
  (synchronous). Individual provider refreshes still run off the task
  supervisor, so tests should `assert_receive` on their side-effects.
  """
  @spec probe(GenServer.server()) :: :ok
  def probe(server \\ __MODULE__), do: GenServer.call(server, :probe, 60_000)

  @doc "A snapshot of the probe state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    state = %State{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      refresh_fun: Keyword.get(opts, :refresh_fun) || (&default_refresh/1),
      oauth_opts: Keyword.get(opts, :oauth_opts, [])
    }

    if state.enabled, do: schedule(self(), state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state) do
    {:reply, %{probe_count: state.probe_count, enabled: state.enabled}, state}
  end

  def handle_call(:probe, _from, %State{} = state) do
    {:reply, :ok, do_probe_cycle(state)}
  end

  @impl true
  def handle_info(:probe, %State{enabled: false} = state) do
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:probe, %State{} = state) do
    new_state = do_probe_cycle(state)
    schedule(self(), state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info({:oauth_usage_refresh_result, workspace_ids, result}, %State{} = state) do
    {:noreply, note_oauth_result(state, workspace_ids, result)}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # ---- probe logic -------------------------------------------------------

  defp do_probe_cycle(%State{enabled: false} = state), do: state

  defp do_probe_cycle(%State{} = state) do
    workspaces = list_workspaces()

    if workspaces != [] do
      Logger.debug("Arbiter.Quota.CloudProbe: refreshing #{length(workspaces)} workspace(s)")
      spawn_oauth_usage_refresh(workspaces, state.oauth_opts)
      Enum.each(workspaces, &spawn_refresh(state.refresh_fun, &1.id))
    end

    %{state | probe_count: state.probe_count + 1}
  end

  # `/api/oauth/usage` is account-wide, and this install has exactly one
  # account credential — the operator's `~/.claude/.credentials.json` — behind
  # every workspace, so it is fetched exactly once per cycle for the whole
  # fleet and the result is written to every workspace (see the moduledoc for
  # why this no longer groups by, or passes, a per-workspace token — bd-4fbpto).
  defp spawn_oauth_usage_refresh(workspaces, oauth_opts) do
    workspace_ids = Enum.map(workspaces, & &1.id)
    parent = self()

    spawn_task(fn ->
      result = call_oauth_usage_refresh(workspace_ids, oauth_opts)
      send(parent, {:oauth_usage_refresh_result, workspace_ids, result})
    end)
  end

  defp call_oauth_usage_refresh(workspace_ids, oauth_opts) do
    case Arbiter.Quota.capture_oauth_usage_for_group(workspace_ids, oauth_opts) do
      {:error, reason} = err ->
        Logger.warning(
          "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} failed: #{inspect(reason)}"
        )

        err

      ok ->
        ok
    end
  rescue
    e ->
      reason = {:exception, Exception.message(e)}

      Logger.warning(
        "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} raised: #{Exception.message(e)}"
      )

      {:error, reason}
  catch
    :exit, r ->
      Logger.warning(
        "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} exited: #{inspect(r)}"
      )

      {:error, {:exit, r}}
  end

  # Tracks consecutive oauth-usage-poll failures and escalates to the
  # coordinator mailbox the cycle the threshold is first crossed — an
  # edge-trigger, so a sustained outage produces exactly one mailbox item
  # (bd-4fbpto) rather than one per 5-minute cycle. Resets on the next
  # success, so a later, distinct outage escalates again.
  defp note_oauth_result(%State{} = state, _workspace_ids, {:ok, _}) do
    %{state | oauth_consecutive_failures: 0}
  end

  defp note_oauth_result(%State{} = state, workspace_ids, {:error, reason}) do
    failures = state.oauth_consecutive_failures + 1

    if failures == @oauth_failure_escalation_threshold do
      escalate_oauth_failure(workspace_ids, failures, reason)
    end

    %{state | oauth_consecutive_failures: failures}
  end

  defp note_oauth_result(%State{} = state, _workspace_ids, _other), do: state

  defp escalate_oauth_failure([ws_id | _], failures, reason) when is_binary(ws_id) do
    safe_escalate(fn ->
      CoordinatorNotifier.quota_poll_failing(%{workspace_id: ws_id}, failures, reason)
    end)
  end

  defp escalate_oauth_failure(_workspace_ids, _failures, _reason), do: :ok

  defp safe_escalate(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudProbe: escalation swallowed: #{Exception.message(e)}")
  catch
    :exit, _ -> :ok
  end

  defp spawn_refresh(refresh_fun, workspace_id) do
    spawn_task(fn -> call_refresh(refresh_fun, workspace_id) end)
  end

  defp spawn_task(fun) do
    supervisor = Arbiter.Quota.CloudProbeSupervisor

    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(pid, fun)

      _ ->
        spawn(fun)
    end
  rescue
    _ -> :ok
  end

  defp call_refresh(refresh_fun, workspace_id) do
    refresh_fun.(workspace_id)
  rescue
    e ->
      Logger.debug(
        "Arbiter.Quota.CloudProbe: refresh for #{workspace_id} raised: #{Exception.message(e)}"
      )
  catch
    :exit, r ->
      Logger.debug("Arbiter.Quota.CloudProbe: refresh for #{workspace_id} exited: #{inspect(r)}")
  end

  # The real per-workspace provider refresh. Each call persists + broadcasts
  # on success and no-ops (no row written) when its credentials aren't
  # present on this host. Anthropic's `/api/oauth/usage` source (per-model
  # weekly + overage + the primary gate columns) is refreshed separately, once
  # per cycle for the whole fleet, by `spawn_oauth_usage_refresh/2` — see that
  # function and bd-4fbpto for why it isn't fanned out per workspace here.
  defp default_refresh(workspace_id) do
    Arbiter.Quota.Codex.fetch(workspace_id)
    Arbiter.Quota.CloudCode.refresh(workspace_id, :gemini)
    Arbiter.Quota.CloudCode.refresh(workspace_id, :antigravity)
    :ok
  end

  # ---- helpers -----------------------------------------------------------

  defp list_workspaces do
    case Ash.read(Arbiter.Tasks.Workspace) do
      {:ok, workspaces} -> workspaces
      _ -> []
    end
  rescue
    _ -> []
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :probe, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case Application.get_env(:arbiter, :cloud_quota_probe, []) do
          kw when is_list(kw) -> Keyword.get(kw, key, default)
          _ -> default
        end
    end
  end
end
