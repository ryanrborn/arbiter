defmodule Arbiter.Board.Autopilot do
  @moduledoc """
  The process that actually promotes. `Arbiter.Board.Scheduler` decides *which*
  Ready card should go next; this is the thing that goes and dispatches it.

  The board's Ready column is a queue, not a staging area — the handoff's
  "drop to dispatch" zone is deliberately not built (bd-bqyeqa). An operator
  who has to drag every card into Running is a scheduler made of a person, and
  a person is the one component in this system that cannot watch sixteen slots
  at once. So the queue drains itself: on each tick the autopilot reads the
  board, and if `Arbiter.Board.Snapshot` named a card to promote, it dispatches
  exactly that one card.

  ## One card per tick

  `Scheduler.plan/1` promotes at most one card even when several slots are
  free, and this process does not loop to catch up. Dispatch is slow and has
  side effects — a worktree, a branch, possibly a paid agent session — and a
  card that has just been dispatched does not appear as in-flight work until
  its worker registers. Promoting one card per tick means the next tick reads a
  world that already contains the previous promotion, so file-overlap and slot
  accounting stay honest without this module having to model in-flight
  dispatches itself.

  ## Paused by default

  The autopilot starts paused unless the install opts in
  (`config :arbiter, :board_autopilot, enabled: true`, or `paused: false` at
  start). Auto-dispatch spends money and touches a git worktree; an install
  that upgrades into this feature should not discover it by finding four
  agents running. Pause state lives in the process, not the database: a
  restart returns to the configured default, which is the safe direction to
  fail.

  While paused the board still renders a full plan — every Ready card reads
  `scheduler paused` rather than a queue position, because a position implies
  a queue that is moving.
  """

  use GenServer

  alias Arbiter.Board.Snapshot

  require Logger

  @topic "board"
  @default_interval_ms 15_000

  @typedoc "What one tick did."
  @type outcome :: {:ok, String.t()} | {:error, term()} | :idle | :paused

  @doc """
  The PubSub topic carrying `{:board_dispatched, task_id}` and
  `{:board_scheduler, :paused | :resumed}`. Open boards subscribe here so a
  promotion shows up without polling.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Start the autopilot.

  Options:

    * `:name` — registered name; defaults to this module. Pass `nil` for an
      anonymous instance (tests).
    * `:paused` — initial pause state; defaults to the app env.
    * `:interval_ms` — tick period, or `:never` to only tick when asked.
    * `:snapshot` / `:dispatch` — seams for tests; default to
      `Snapshot.load/1` and `Arbiter.Worker.Dispatch.dispatch/1`.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Run one dispatch cycle now and report what it did."
  @spec tick(GenServer.server()) :: outcome()
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc """
  The board as this process sees it, with `:paused` set from its own state so
  the reasons on screen describe the scheduler that is actually running.
  """
  @spec board(GenServer.server(), keyword()) :: Snapshot.t()
  def board(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:board, opts})

  @doc "Stop promoting. Cards in flight keep running; the queue just stops draining."
  @spec pause(GenServer.server()) :: :ok
  def pause(server \\ __MODULE__), do: GenServer.call(server, {:paused, true})

  @doc "Start promoting again. The next tick may dispatch."
  @spec resume(GenServer.server()) :: :ok
  def resume(server \\ __MODULE__), do: GenServer.call(server, {:paused, false})

  @spec paused?(GenServer.server()) :: boolean()
  def paused?(server \\ __MODULE__), do: GenServer.call(server, :paused?)

  @doc """
  Whether this install runs the autopilot at all. A board talking to a
  process that isn't there should say so rather than raise.
  """
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, configured_interval_ms())

    state = %{
      paused?: Keyword.get(opts, :paused, configured_paused?()),
      interval_ms: interval,
      snapshot: Keyword.get(opts, :snapshot, &Snapshot.load/1),
      dispatch: Keyword.get(opts, :dispatch, &default_dispatch/1)
    }

    schedule(interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, promote(state), state}

  def handle_call({:board, opts}, _from, state) do
    {:reply, read_board(state, opts), state}
  end

  def handle_call(:paused?, _from, state), do: {:reply, state.paused?, state}

  def handle_call({:paused, paused?}, _from, state) do
    if paused? != state.paused? do
      announce({:board_scheduler, if(paused?, do: :paused, else: :resumed)})
    end

    {:reply, :ok, %{state | paused?: paused?}}
  end

  @impl true
  def handle_info(:tick, state) do
    promote(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- one cycle -----------------------------------------------------------

  defp promote(%{paused?: true}), do: :paused

  defp promote(state) do
    case read_board(state, []) do
      %{promote: id} when is_binary(id) -> dispatch(state, id)
      _ -> :idle
    end
  end

  defp dispatch(state, id) do
    case state.dispatch.(id) do
      {:ok, _} ->
        announce({:board_dispatched, id})
        {:ok, id}

      {:error, reason} = error ->
        # A dispatch that fails is a fact about that card, not about the
        # scheduler: log it and let the next tick re-read the world. The card
        # is still Ready, so it is simply reconsidered — no retry bookkeeping.
        Logger.warning("board autopilot: dispatch of #{id} failed: #{inspect(reason)}")
        error

      other ->
        Logger.warning("board autopilot: dispatch of #{id} returned #{inspect(other)}")
        {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # The board always reports *this* process's pause state, so a caller can
  # never render "2 ahead in queue" against a scheduler that is stopped.
  defp read_board(state, opts) do
    state.snapshot.(Keyword.put(opts, :paused, state.paused?))
  rescue
    e ->
      Logger.warning("board autopilot: board read failed: #{inspect(e)}")
      Snapshot.empty()
  end

  defp default_dispatch(id), do: Arbiter.Worker.Dispatch.dispatch(id)

  defp announce(message) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, @topic, message)
  rescue
    _ -> :ok
  end

  defp schedule(:never), do: :ok
  defp schedule(ms) when is_integer(ms) and ms > 0, do: Process.send_after(self(), :tick, ms)
  defp schedule(_), do: :ok

  # `:never` in the test env: a resumed autopilot must not dispatch a real
  # worker behind a test's back.
  defp configured_interval_ms do
    :arbiter
    |> Application.get_env(:board_autopilot, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp configured_paused? do
    :arbiter
    |> Application.get_env(:board_autopilot, [])
    |> Keyword.get(:enabled, false)
    |> Kernel.!()
  end
end
