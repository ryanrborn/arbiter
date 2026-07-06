defmodule Arbiter.Quota.RefreshProbe do
  @moduledoc """
  Periodic lightweight probe to keep the Anthropic quota snapshot fresh (bd-jzg8t0).

  ## Motivation

  The quota snapshot is only refreshed when worker traffic flows through the
  local proxy. When the fleet is idle the snapshot goes stale, and a stale
  high-utilisation snapshot can hold the DispatchQueue indefinitely — a
  chicken-and-egg: the throttle blocks the very traffic that would update the
  number it throttles on.

  ## What this does

  On a recurring timer this GenServer considers issuing one tiny
  `claude --print "ok"` request **per workspace** through that workspace's
  quota proxy URL (`Arbiter.Quota.worker_base_url/1`). The proxy captures the
  response's `anthropic-ratelimit-unified-*` headers, upserts a fresh
  `AnthropicQuota` snapshot, and broadcasts `{:quota_updated, ws_id, quota}`
  on PubSub — which the DispatchQueue listens for and uses to drain any held
  intents.

  A real probe always spends actual quota/tokens, so each workspace is only
  probed when it is likely to actually help (bd-6bp05l, mirroring 9router's
  `quotaAutoPing.js`):

    * No snapshot exists yet for the workspace — probe, to get the clock
      started.
    * The latest snapshot's 5h window has already elapsed
      (`Arbiter.Quota.Gate.stale?/1`) — probe, to observe the new window's
      state promptly (the "reset boundary" case).
    * Otherwise the workspace is skipped: a fresh, non-exhausted snapshot
      doesn't need a real request to stay useful, and a fresh *exhausted*
      snapshot can't be relieved by probing anyway — only the window's
      actual reset does that, which the `stale?/1` case above picks up on
      the next cycle.

  ## Gate bypass

  The probe runs outside `Arbiter.Worker.Dispatch`, so it is never subject to
  the QuotaGate. It runs even when the gate would hold real worker dispatches.

  ## Cadence

  * `active_interval_ms` (default 5 min) — used when any DispatchQueue has
    held intents, so a blocked fleet gets a prompt refresh.
  * `idle_interval_ms` (default 15 min) — used when no intents are held; a
    low heartbeat keeps the snapshot from going fully stale.

  No probe is issued when `Arbiter.Quota.proxy_enabled?/0` is false (proxy
  disabled or not configured) — there is nothing to refresh.

  ## Configuration

  Via `config :arbiter, :quota_refresh_probe`:

    * `:enabled`             — master switch (default `true`; `false` in test).
    * `:active_interval_ms`  — probe interval when queues are held (default 300 000).
    * `:idle_interval_ms`    — heartbeat interval when queues are empty (default 900 000).
    * `:probe_timeout_ms`    — per-workspace probe wall-clock timeout (default 30 000).

  ## Test injection

  Pass `:probe_fun` — a `fn(workspace_id :: String.t()) :: :ok | {:error, term()}` —
  to `start_link/1` to replace the default `claude --print` shell-out with any
  arbitrary implementation. Tests pass a stub that calls `Arbiter.Quota.capture/3`
  directly with fake headers, so there is no dependency on the real CLI.
  """

  use GenServer
  require Logger

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueueSupervisor

  @default_active_interval_ms 300_000
  @default_idle_interval_ms 900_000
  @default_probe_timeout_ms 30_000

  defmodule State do
    @moduledoc false
    defstruct [
      :active_interval_ms,
      :idle_interval_ms,
      :probe_fun,
      :enabled,
      probe_count: 0
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
  Force an immediate probe cycle and wait for it to complete (synchronous).
  Useful in tests that need to assert on the side-effects of a probe.
  """
  @spec probe(GenServer.server()) :: :ok
  def probe(server \\ __MODULE__), do: GenServer.call(server, :probe, 60_000)

  @doc "Return a snapshot of the probe state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    timeout_ms = cfg(:probe_timeout_ms, opts, @default_probe_timeout_ms)

    probe_fun =
      Keyword.get(opts, :probe_fun) ||
        fn ws_id -> default_probe(ws_id, timeout_ms) end

    state = %State{
      enabled: cfg(:enabled, opts, true),
      active_interval_ms: cfg(:active_interval_ms, opts, @default_active_interval_ms),
      idle_interval_ms: cfg(:idle_interval_ms, opts, @default_idle_interval_ms),
      probe_fun: probe_fun
    }

    if state.enabled, do: schedule(self(), state.idle_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state) do
    {:reply, %{probe_count: state.probe_count, enabled: state.enabled}, state}
  end

  def handle_call(:probe, _from, %State{} = state) do
    {_active?, new_state} = do_probe_cycle(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:probe, %{enabled: false} = state) do
    schedule(self(), state.idle_interval_ms)
    {:noreply, state}
  end

  def handle_info(:probe, %State{} = state) do
    {active?, new_state} = do_probe_cycle(state)
    next_ms = if active?, do: state.active_interval_ms, else: state.idle_interval_ms
    schedule(self(), next_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # ---- probe logic -------------------------------------------------------

  defp do_probe_cycle(%State{} = state) do
    if Arbiter.Quota.proxy_enabled?() do
      workspaces = list_workspaces()
      held_count = count_held_workspaces()
      active? = held_count > 0
      due = Enum.filter(workspaces, &due_for_probe?/1)

      if workspaces != [] do
        Logger.debug(
          "Arbiter.Quota.RefreshProbe: #{length(due)}/#{length(workspaces)} workspace(s) due for a real probe" <>
            if(active?, do: ", #{held_count} with held dispatch intents", else: "")
        )
      end

      Enum.each(due, fn workspace ->
        spawn_probe(state.probe_fun, workspace.id)
      end)

      {active?, %{state | probe_count: state.probe_count + 1}}
    else
      {false, state}
    end
  end

  # Whether `workspace` is worth spending a real probe request on right now:
  # no snapshot yet, or its 5h window has already rolled (reset-boundary
  # warm-up). A fresh snapshot — exhausted or not — is skipped; see moduledoc.
  defp due_for_probe?(workspace) do
    case Arbiter.Quota.latest(workspace.id) do
      nil -> true
      quota -> Arbiter.Quota.Gate.stale?(quota)
    end
  end

  defp spawn_probe(probe_fun, workspace_id) do
    supervisor = Arbiter.Quota.RefreshProbeSupervisor

    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(pid, fn ->
          call_probe_fun(probe_fun, workspace_id)
        end)

      _ ->
        spawn(fn -> call_probe_fun(probe_fun, workspace_id) end)
    end
  rescue
    _ -> :ok
  end

  defp call_probe_fun(probe_fun, workspace_id) do
    probe_fun.(workspace_id)
  rescue
    e ->
      Logger.debug(
        "Arbiter.Quota.RefreshProbe: probe for #{workspace_id} raised: #{Exception.message(e)}"
      )
  catch
    :exit, r ->
      Logger.debug(
        "Arbiter.Quota.RefreshProbe: probe for #{workspace_id} exited: #{inspect(r)}"
      )
  end

  # ---- default probe (real claude CLI) -----------------------------------

  defp default_probe(workspace_id, timeout_ms) do
    with {:ok, sh} <- find_executable("sh"),
         {:ok, claude} <- find_executable("claude") do
      base_url = Arbiter.Quota.worker_base_url(workspace_id)
      env = probe_env(base_url)
      rest_args = ["-c", ~s(exec "$@" < /dev/null), "sh", claude, "--print", "ok"]
      run_port(sh, rest_args, env, workspace_id, timeout_ms)
    else
      {:error, {:not_found, what}} ->
        Logger.debug(
          "Arbiter.Quota.RefreshProbe: skipping #{workspace_id} — #{what} not on PATH"
        )

        {:error, {:not_found, what}}
    end
  end

  defp probe_env(base_url) do
    ConfigDir.env() ++ [{"ANTHROPIC_BASE_URL", base_url}]
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:not_found, name}}
      path -> {:ok, path}
    end
  end

  defp run_port(exec_path, rest_args, env, workspace_id, timeout_ms) do
    env_opt =
      if env == [],
        do: [],
        else: [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]

    port =
      Port.open(
        {:spawn_executable, exec_path},
        [{:args, rest_args}, :binary, :exit_status, :stderr_to_stdout | env_opt]
      )

    await_exit(port, workspace_id, timeout_ms)
  rescue
    e ->
      Logger.debug(
        "Arbiter.Quota.RefreshProbe: probe spawn failed (#{workspace_id}): #{Exception.message(e)}"
      )

      {:error, :spawn_failed}
  end

  defp await_exit(port, workspace_id, timeout_ms) do
    receive do
      {^port, {:data, _}} ->
        await_exit(port, workspace_id, timeout_ms)

      {^port, {:exit_status, 0}} ->
        Logger.debug("Arbiter.Quota.RefreshProbe: probe ok (#{workspace_id})")
        :ok

      {^port, {:exit_status, code}} ->
        Logger.debug(
          "Arbiter.Quota.RefreshProbe: probe exited #{code} (#{workspace_id})"
        )

        {:error, {:exit_code, code}}
    after
      timeout_ms ->
        safe_close(port)

        Logger.debug(
          "Arbiter.Quota.RefreshProbe: probe timed out after #{timeout_ms}ms (#{workspace_id})"
        )

        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
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

  defp count_held_workspaces do
    DispatchQueueSupervisor.list_queues()
    |> Enum.count(fn {_ws_id, pid} ->
      try do
        pid |> DispatchQueue.state() |> Map.get(:items, []) |> Enum.any?()
      catch
        :exit, _ -> false
      end
    end)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :probe, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case Application.get_env(:arbiter, :quota_refresh_probe, []) do
          kw when is_list(kw) -> Keyword.get(kw, key, default)
          _ -> default
        end
    end
  end
end
