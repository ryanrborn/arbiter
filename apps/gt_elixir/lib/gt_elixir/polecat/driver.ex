defmodule GtElixir.Polecat.Driver do
  @moduledoc """
  Ticks a `GtElixir.Workflows.Machine` forward and mirrors its progress
  onto the paired `GtElixir.Polecat`. Closes the bead when the workflow
  completes.

  Started by `GtElixir.Polecat.Sling.sling/2` after a polecat and machine
  are paired. Lives under `GtElixir.Polecat.Supervisor`.

  ## Lifecycle

  - On start: schedules the first tick immediately.
  - On each tick: calls `Machine.advance/1` and reacts:
    - `{:ok, :completed}` → `Polecat.complete/2`, close the bead, stop.
    - `{:ok, next_step}` → `Polecat.advance/2`, schedule next tick.
    - `{:error, reason}` → `Polecat.fail/2`, stop (bead remains `:in_progress`).
  - On polecat or machine `:DOWN`: stop cleanly; if the machine died first,
    mark the polecat `:failed`.

  ## Safety backstop

  A `:max_ticks` option (default 50) bounds the loop so a buggy workflow
  can't spin forever. 50 ticks at 100ms is 5 seconds of placeholder
  workflow time — plenty for the no-op steps in `Workflows.Work`. Real
  workflows that need to wait on async events should use `Polecat.await/2`
  (and a future event-driven driver) rather than longer ticks.

  ## What this does NOT do (yet)

  - Launch a Claude subprocess. The workflow's `run_step/2` is currently a
    no-op for `:design`/`:implement`/`:pre_verify`. Wiring
    `GtElixir.Polecat.ClaudeSession.start/1` into the polecat's
    `:running` transition is the next bead.
  - Provision a worktree. `Sling` still passes `worktree_path: nil`.
    Worktree provisioning is the bead after that.
  - Retry on failure. A failed workflow leaves the bead in `:in_progress`
    for operator inspection.
  """

  use GenServer
  require Logger

  alias GtElixir.Beads.Issue
  alias GtElixir.Polecat
  alias GtElixir.Polecat.Worktree
  alias GtElixir.Workflows.Machine

  @default_interval_ms 100
  @default_max_ticks 50

  @type opts :: [
          bead_id: String.t(),
          polecat_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          interval_ms: non_neg_integer(),
          max_ticks: non_neg_integer(),
          worktree_path: String.t() | nil,
          cleanup_worktree: boolean()
        ]

  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(GtElixir.Polecat.Supervisor, {__MODULE__, opts})
  end

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      bead_id: Keyword.fetch!(opts, :bead_id),
      polecat_pid: Keyword.fetch!(opts, :polecat_pid),
      machine_id: Keyword.fetch!(opts, :machine_id),
      machine_pid: Keyword.fetch!(opts, :machine_pid),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_ticks: Keyword.get(opts, :max_ticks, @default_max_ticks),
      worktree_path: Keyword.get(opts, :worktree_path),
      cleanup_worktree: Keyword.get(opts, :cleanup_worktree, false),
      ticks: 0
    }

    Process.monitor(state.polecat_pid)
    Process.monitor(state.machine_pid)

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{ticks: t, max_ticks: m} = state) when t >= m do
    Logger.warning(
      "Polecat.Driver hit max_ticks=#{m} for bead=#{state.bead_id}; stopping"
    )

    safe(fn -> Polecat.fail(state.polecat_pid, {:driver_timeout, m}) end)
    {:stop, :normal, state}
  end

  def handle_info(:tick, state) do
    case safe_advance(state.machine_pid) do
      {:ok, :completed} ->
        safe(fn -> Polecat.complete(state.polecat_pid, :workflow_completed) end)
        close_bead(state.bead_id)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      {:ok, next_step} when is_atom(next_step) ->
        safe(fn -> Polecat.advance(state.polecat_pid, next_step) end)
        schedule_tick(state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      {:error, reason} ->
        Logger.warning(
          "Polecat.Driver: machine.advance error for bead=#{state.bead_id}: #{inspect(reason)}"
        )

        safe(fn -> Polecat.fail(state.polecat_pid, reason) end)
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{polecat_pid: pid} = state) do
    Logger.warning("Polecat.Driver: polecat died for bead=#{state.bead_id}")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{machine_pid: pid} = state) do
    Logger.warning("Polecat.Driver: machine died for bead=#{state.bead_id}")
    safe(fn -> Polecat.fail(state.polecat_pid, :machine_died) end)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ---------------------------------------------------------

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp safe_advance(machine_pid) do
    Machine.advance(machine_pid)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp close_bead(bead_id) do
    with {:ok, bead} <- Ash.get(Issue, bead_id),
         {:ok, _} <- Ash.update(bead, %{}, action: :close) do
      :ok
    else
      err ->
        Logger.warning(
          "Polecat.Driver: failed to close bead #{bead_id}: #{inspect(err)}"
        )

        :error
    end
  end

  # Best-effort worktree cleanup after a successful workflow.
  #
  # Skipped when:
  #   - `cleanup_worktree` is false (default)
  #   - `worktree_path` is nil (no worktree was provisioned)
  #   - the worktree has uncommitted changes (operator should inspect)
  #
  # Failures are logged but never propagated — the bead is already closed
  # and the workflow is done, so we don't want to crash the Driver over a
  # cleanup hiccup.
  defp maybe_cleanup_worktree(%{cleanup_worktree: false}), do: :ok
  defp maybe_cleanup_worktree(%{worktree_path: nil}), do: :ok

  defp maybe_cleanup_worktree(%{worktree_path: path, bead_id: bead_id}) do
    case Worktree.has_uncommitted?(path) do
      {:ok, false} ->
        case Worktree.cleanup(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Polecat.Driver: cleanup_worktree failed for bead=#{bead_id}: #{inspect(reason)}"
            )
        end

      {:ok, true} ->
        Logger.info(
          "Polecat.Driver: worktree has uncommitted changes for bead=#{bead_id}; skipping cleanup"
        )

      {:error, reason} ->
        Logger.warning(
          "Polecat.Driver: cleanup probe failed for bead=#{bead_id}: #{inspect(reason)}"
        )
    end

    :ok
  end
end
