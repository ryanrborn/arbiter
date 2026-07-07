defmodule Arbiter.Quota.CloudProbe do
  @moduledoc """
  Periodic refresh probe for the *non-Anthropic* quota providers — Codex,
  Gemini CLI, and Antigravity (bd-ajh7bd).

  ## Motivation

  Claude quota stays fresh on its own: the local proxy scrapes rate-limit
  headers off every worker request and `Arbiter.Quota.RefreshProbe` tops it up
  when the fleet is idle. Codex / Gemini CLI / Antigravity have no such passive
  signal — their figures only ever came from a *live fetch on each
  `GET /api/quota` call*, and (before this change) Gemini/Antigravity were never
  persisted at all. So the web dashboard, which reads only the persisted quota
  tables, could never show them, and there was no history to audit.

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
    * `Arbiter.Quota.capture_oauth_usage/2` — Anthropic's *secondary*
      `/api/oauth/usage` source (per-model weekly + `extra_usage` overage,
      bd-8tpha6). The header-capture `RefreshProbe` keeps Claude's primary
      aggregate fresh, but once the quota surface stopped fetching live nothing
      else refreshed this layer, so it rides along here (best-effort; its own
      429 cooldown protects it).

  Each degrades to a no-op (no row written, no broadcast) when its CLI isn't
  authenticated on this host, so a logged-out provider simply never appears
  rather than wiping the last good reading. Credentials are host-global, so the
  figures written under each workspace id are identical — we still fan out per
  workspace (mirroring `RefreshProbe`) so every workspace's dashboard is fed.

  ## Cadence

  A single `interval_ms` (default 5 min). Unlike `RefreshProbe`, these are
  cheap metadata calls that spend no model quota, so there's no active/idle
  split or reset-boundary gating — a plain heartbeat is enough.

  ## Configuration

  Via `config :arbiter, :cloud_quota_probe`:

    * `:enabled`     — master switch (default `true`; `false` in test).
    * `:interval_ms` — refresh interval (default 300 000).

  ## Test injection

  Pass `:refresh_fun` — a `fn(workspace_id :: String.t()) :: any()` — to
  `start_link/1` to replace the default three-provider refresh. Tests pass a
  stub so there is no dependency on real CLIs or HTTP.
  """

  use GenServer
  require Logger

  @default_interval_ms 300_000

  defmodule State do
    @moduledoc false
    defstruct [:interval_ms, :refresh_fun, :enabled, probe_count: 0]
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
      refresh_fun: Keyword.get(opts, :refresh_fun) || (&default_refresh/1)
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

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # ---- probe logic -------------------------------------------------------

  defp do_probe_cycle(%State{enabled: false} = state), do: state

  defp do_probe_cycle(%State{} = state) do
    workspaces = list_workspaces()

    if workspaces != [] do
      Logger.debug("Arbiter.Quota.CloudProbe: refreshing #{length(workspaces)} workspace(s)")
      Enum.each(workspaces, &spawn_refresh(state.refresh_fun, &1.id))
    end

    %{state | probe_count: state.probe_count + 1}
  end

  defp spawn_refresh(refresh_fun, workspace_id) do
    supervisor = Arbiter.Quota.CloudProbeSupervisor

    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(pid, fn -> call_refresh(refresh_fun, workspace_id) end)

      _ ->
        spawn(fn -> call_refresh(refresh_fun, workspace_id) end)
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

  # The real refresh. Each call persists + broadcasts on success and no-ops (no
  # row written) when its credentials aren't present on this host. Since the
  # controller / MCP quota surface no longer fetches live (bd-ajh7bd), this
  # probe also tops up Anthropic's *secondary* `/api/oauth/usage` source
  # (per-model weekly + overage, bd-8tpha6) — the header-capture RefreshProbe
  # keeps the primary Claude aggregate fresh, but nothing else refreshes the
  # oauth-usage layer once it's out of the request path.
  defp default_refresh(workspace_id) do
    Arbiter.Quota.capture_oauth_usage(workspace_id)
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
