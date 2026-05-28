defmodule Arbiter.Polecat.Driver do
  @moduledoc """
  Drives a bead to completion. Has two modes:

  ### Workflow mode (default)

  Ticks `Arbiter.Workflows.Machine` forward and mirrors its progress onto
  the paired `Arbiter.Polecat`. Closes the bead when the workflow
  completes. Used for bookkeeping-only polecats.

  ### Claude-driven mode (`claude_driven: true`)

  A Claude subprocess is doing the real work; the Driver does NOT tick the
  Machine. Instead it polls the polecat's status and closes the bead when
  the polecat reaches `:completed` (typically triggered by Claude printing
  `gt done` on stdout — see `Polecat.ClaudeSession`).

  This mode resolves the Driver/Claude race that `arb sling --with-claude`
  exposed: the bookkeeping workflow used to finish in ~500ms and close the
  bead before Claude had time to respond.

  ## Lifecycle (workflow mode)

  - On start: schedules the first tick immediately.
  - On each tick: calls `Machine.advance/1` and reacts:
    - `{:ok, :completed}` → `Polecat.complete/2`, close the bead, stop.
    - `{:ok, next_step}` → `Polecat.advance/2`, schedule next tick.
    - `{:error, reason}` → `Polecat.fail/2`, stop (bead remains `:in_progress`).

  ## Lifecycle (claude-driven mode)

  - On start: schedules the first polecat check.
  - On each check: reads polecat status:
    - `:completed` → close the bead, optionally cleanup worktree, stop.
    - `:failed` → log, stop (bead remains `:in_progress` for inspection).
    - `:idle | :running | :awaiting` → schedule next check.

  ## Shared lifecycle

  - On polecat or machine `:DOWN`: stop cleanly; if the machine died first
    (workflow mode), mark the polecat `:failed`.

  ## Safety backstops

  `:max_ticks` bounds the loop. Defaults differ by mode:
    - workflow mode: 50 ticks × 100ms = 5 seconds (plenty for no-op steps).
    - claude-driven mode: 1800 ticks × 1000ms = 30 minutes (room for real
      Claude work; tune via the `:max_ticks` and `:interval_ms` opts).
  """

  use GenServer
  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Worktree
  alias Arbiter.Workflows.Machine

  @workflow_default_interval_ms 100
  @workflow_default_max_ticks 50

  @claude_default_interval_ms 1_000
  @claude_default_max_ticks 1_800

  @type opts :: [
          bead_id: String.t(),
          polecat_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          interval_ms: non_neg_integer(),
          max_ticks: non_neg_integer(),
          worktree_path: String.t() | nil,
          cleanup_worktree: boolean(),
          claude_driven: boolean()
        ]

  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Polecat.Supervisor, {__MODULE__, opts})
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
    claude_driven = Keyword.get(opts, :claude_driven, false)

    state = %{
      bead_id: Keyword.fetch!(opts, :bead_id),
      polecat_pid: Keyword.fetch!(opts, :polecat_pid),
      machine_id: Keyword.fetch!(opts, :machine_id),
      machine_pid: Keyword.fetch!(opts, :machine_pid),
      claude_driven: claude_driven,
      interval_ms: Keyword.get(opts, :interval_ms, default_interval_for(claude_driven)),
      max_ticks: Keyword.get(opts, :max_ticks, default_max_ticks_for(claude_driven)),
      worktree_path: Keyword.get(opts, :worktree_path),
      cleanup_worktree: Keyword.get(opts, :cleanup_worktree, false),
      ticks: 0
    }

    Process.monitor(state.polecat_pid)
    Process.monitor(state.machine_pid)

    schedule_first(state)
    {:ok, state}
  end

  defp default_interval_for(true), do: @claude_default_interval_ms
  defp default_interval_for(false), do: @workflow_default_interval_ms

  defp default_max_ticks_for(true), do: @claude_default_max_ticks
  defp default_max_ticks_for(false), do: @workflow_default_max_ticks

  defp schedule_first(%{claude_driven: true}), do: Process.send_after(self(), :check_polecat, 0)
  defp schedule_first(%{claude_driven: false}), do: Process.send_after(self(), :tick, 0)

  @impl true
  def handle_info(:tick, %{ticks: t, max_ticks: m} = state) when t >= m do
    Logger.warning("Polecat.Driver hit max_ticks=#{m} for bead=#{state.bead_id}; stopping")

    safe(fn -> Polecat.fail(state.polecat_pid, {:driver_timeout, m}) end)
    {:stop, :normal, state}
  end

  def handle_info(:check_polecat, %{ticks: t, max_ticks: m} = state) when t >= m do
    Logger.warning(
      "Polecat.Driver (claude_driven) hit max_ticks=#{m} for bead=#{state.bead_id}; stopping"
    )

    {:stop, :normal, state}
  end

  def handle_info(:check_polecat, state) do
    case safe_polecat_state(state.polecat_pid) do
      %{status: :completed} ->
        close_bead(state.bead_id)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{status: :failed} ->
        Logger.warning(
          "Polecat.Driver (claude_driven): polecat failed for bead=#{state.bead_id}; leaving bead :in_progress"
        )

        {:stop, :normal, state}

      %{status: status} when status in [:idle, :running, :awaiting] ->
        Process.send_after(self(), :check_polecat, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      nil ->
        # Polecat snapshot unavailable (process likely dead) — the :DOWN
        # handler will fire next, just stop trying for now.
        Process.send_after(self(), :check_polecat, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}
    end
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

  defp safe_polecat_state(pid) do
    Polecat.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
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
        Logger.warning("Polecat.Driver: failed to close bead #{bead_id}: #{inspect(err)}")

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
    cond do
      # The bead's :close after_action already removed the worktree (see
      # Arbiter.Beads.Issue.Changes.CleanupWorktree) — nothing left to do.
      # Returning :ok silently keeps the legacy Driver-side path from
      # logging a warning about a path that is already gone.
      not File.dir?(path) ->
        :ok

      worktree_dirty?(path, bead_id) ->
        Logger.info(
          "Polecat.Driver: worktree has uncommitted changes for bead=#{bead_id}; skipping cleanup"
        )

      worktree_ahead_of_base?(path, bead_id) ->
        Logger.info(
          "Polecat.Driver: worktree has commits ahead of base for bead=#{bead_id}; skipping cleanup"
        )

      true ->
        case Worktree.cleanup(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Polecat.Driver: cleanup_worktree failed for bead=#{bead_id}: #{inspect(reason)}"
            )
        end
    end

    :ok
  end

  defp worktree_dirty?(path, bead_id) do
    case Worktree.has_uncommitted?(path) do
      {:ok, dirty} ->
        dirty

      {:error, reason} ->
        Logger.warning(
          "Polecat.Driver: cleanup-dirty-probe failed for bead=#{bead_id}: #{inspect(reason)}"
        )

        # Conservative: treat probe failure as "might be dirty" — skip cleanup.
        true
    end
  end

  defp worktree_ahead_of_base?(path, _bead_id) do
    # `Worktree.has_commits_ahead?/2` already swallows git errors and
    # returns {:ok, true} as the conservative default, so we only need
    # to handle the OK shape here.
    case Worktree.has_commits_ahead?(path, "main") do
      {:ok, ahead?} -> ahead?
    end
  end
end
