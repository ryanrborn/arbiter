defmodule Arbiter.Loop.CanaryTicker do
  @moduledoc """
  The driver behind Stage 3's *auto*-revert (bd-6edc0u).

  `Arbiter.Loop.Canary` knows how to start, judge, promote and revert a canary,
  but something has to ask it to. If that something were the operator, the
  revert would not be automatic — it would be a chore with a nicer name. This
  singleton GenServer walks every workspace on a timer and calls
  `Canary.tick/2` on each, so a regressing routing rule is taken back on its own
  within one interval of the evidence arriving.

  For a workspace that has not set `loop.autonomous_routing_enabled`, `tick/2`
  returns `{:ok, :disabled}` after a single map lookup and nothing else happens
  — no reads, no writes, no mail. That is every workspace by default, which is
  what keeps this process inert until an operator deliberately opts one in. The
  sole exception is a workspace whose flag was unset *while a canary was
  running*: the next tick clears the leftover block, once, so re-enabling the
  flag later starts a clean canary instead of judging a window the canary spent
  switched off (see `Arbiter.Loop.Canary`'s moduledoc).

  Each workspace is ticked under its own rescue: one bad config block, or one
  failed write, must not stop the cycle before it reaches the workspace whose
  canary is regressing.

  ## Configuration

  Via `config :arbiter, :loop_canary_ticker`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `poll/1` synchronously instead).
    * `:interval_ms` — tick interval (default 15 minutes — a canary needs 20
                       dispatches to say anything, so there is nothing to gain
                       from looking more often).
  """

  use GenServer

  require Logger

  alias Arbiter.Loop.Canary
  alias Arbiter.Tasks.Workspace

  @default_interval_ms :timer.minutes(15)

  # ---- public API ----------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one tick cycle synchronously and wait for it to complete.

  Intended for tests and manual triggering; the periodic timer calls the same
  cycle. Returns `:ok`.
  """
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    run_cycle()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_cycle()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals -----------------------------------------------------------

  defp run_cycle do
    Enum.each(workspaces(), &tick_workspace/1)
    :ok
  rescue
    e ->
      Logger.debug("Loop.CanaryTicker cycle swallowed: #{Exception.message(e)}")
      :ok
  end

  defp tick_workspace(workspace) do
    case Canary.tick(workspace, actor: "loop") do
      {:ok, :disabled} ->
        :ok

      {:ok, result} ->
        log(workspace, result)

      {:error, reason} ->
        Logger.warning("Loop.Canary tick failed for workspace #{workspace.id}: #{reason}")
    end
  rescue
    e ->
      Logger.warning(
        "Loop.Canary tick raised for workspace #{workspace.id}: #{Exception.message(e)}"
      )
  end

  # An autonomous change is worth a log line at info even when it went well —
  # `arb` mail carries the operator-facing notice, this carries the timeline.
  defp log(_workspace, :nothing_eligible), do: :ok
  defp log(_workspace, {:running, _stats}), do: :ok

  defp log(workspace, {:started, canary}) do
    Logger.info(
      "Loop.Canary started on #{workspace.id}: D#{canary.difficulty} → " <>
        "#{inspect(canary.rule)} (proposal #{canary.proposal_id})"
    )
  end

  defp log(workspace, {verdict, stats}) when verdict in [:promoted, :reverted] do
    Logger.info(
      "Loop.Canary #{verdict} on #{workspace.id}: D#{stats.difficulty} first-pass " <>
        "convergence #{inspect(stats.canary.first_pass_convergence)} (canary) vs " <>
        "#{inspect(stats.control.first_pass_convergence)} (control) over " <>
        "#{stats.canary.dispatches} dispatch(es); proposal #{stats.proposal_id}"
    )
  end

  defp log(_workspace, _result), do: :ok

  defp workspaces do
    Ash.read!(Workspace)
  rescue
    _ -> []
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :tick, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case get_in(Application.get_env(:arbiter, :loop_canary_ticker, []), [key]) do
          nil -> default
          val -> val
        end
    end
  end
end
