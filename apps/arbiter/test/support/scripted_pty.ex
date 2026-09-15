defmodule Arbiter.Test.ScriptedPty do
  @moduledoc """
  A scripted PTY standing in for `Arbiter.Sessions.Terminal` (bd-3ymdvi,
  phase 4 AC 7: "tests run headlessly against a scripted PTY").

  It is the same shape as the real thing where it matters: `start_stream/3`
  takes a path and the test's `emit/2` **appends raw bytes to that file**,
  exactly as tmux's `pipe-pane … cat >> path` does. So the transport under
  test does the real work — open the file, poll it, frame what it read — and
  nothing about the byte path is faked. What is faked is the terminal: a test
  decides what the pane "prints", how big it is, and when it dies.

  ## Usage

      session = %Session{id: id, tmux_socket: "/nope"}
      ScriptedPty.install(id, snapshot: "scrollback", cols: 80, rows: 24)

      {:ok, _} = Stream.attach(session, terminal: ScriptedPty, ...)
      ScriptedPty.emit(id, "hello\\n")

  State lives in one unlinked, lazily started GenServer keyed by session id,
  so tests stay `async: true` as long as they use distinct session ids (which
  they do — ids are UUIDs).
  """

  @behaviour Arbiter.Sessions.Terminal

  use GenServer

  alias Arbiter.Sessions.Session

  @defaults %{
    snapshot: "",
    cols: 80,
    rows: 24,
    title: "scripted",
    alive?: true,
    streaming?: false,
    path: nil,
    input: <<>>,
    calls: [],
    start_stream_result: :ok
  }

  # -- test API ---------------------------------------------------------------

  @doc "Register a session with the scripted terminal. Returns the session id."
  @spec install(String.t(), keyword()) :: String.t()
  def install(session_id, opts \\ []) do
    state = Map.merge(@defaults, Map.new(opts))
    :ok = GenServer.call(server(), {:install, session_id, state})
    session_id
  end

  @doc "Append bytes to the pipe file, as a pane producing output does."
  @spec emit(String.t(), iodata()) :: :ok
  def emit(session_id, bytes) do
    GenServer.call(server(), {:emit, session_id, IO.iodata_to_binary(bytes)})
  end

  @doc "Change what a `snapshot`/`capture-pane` returns from here on."
  @spec put(String.t(), keyword()) :: :ok
  def put(session_id, opts), do: GenServer.call(server(), {:put, session_id, Map.new(opts)})

  @doc "Everything typed into the pane so far, concatenated."
  @spec input(String.t()) :: binary()
  def input(session_id), do: fetch(session_id).input

  @doc "Recorded calls, oldest first."
  @spec calls(String.t()) :: [tuple()]
  def calls(session_id), do: Enum.reverse(fetch(session_id).calls)

  @doc "The pipe path `start_stream/3` was handed, or nil."
  @spec path(String.t()) :: String.t() | nil
  def path(session_id), do: fetch(session_id).path

  @doc "Current scripted state."
  @spec fetch(String.t()) :: map()
  def fetch(session_id), do: GenServer.call(server(), {:fetch, session_id})

  # -- Terminal behaviour -----------------------------------------------------

  @impl Arbiter.Sessions.Terminal
  def start_stream(%Session{id: id}, path, _opts) do
    GenServer.call(server(), {:start_stream, id, path})
  end

  @impl Arbiter.Sessions.Terminal
  def stop_stream(%Session{id: id}, _opts) do
    GenServer.call(server(), {:record, id, {:stop_stream}, %{streaming?: false}})
  end

  @impl Arbiter.Sessions.Terminal
  def streaming?(%Session{id: id}, _opts), do: fetch(id).streaming?

  @impl Arbiter.Sessions.Terminal
  def snapshot(%Session{id: id}, _opts) do
    state = GenServer.call(server(), {:record_fetch, id, {:snapshot}})
    {:ok, state.snapshot}
  end

  @impl Arbiter.Sessions.Terminal
  def send_input(%Session{id: id}, bytes, _opts) do
    GenServer.call(server(), {:send_input, id, bytes})
  end

  @impl Arbiter.Sessions.Terminal
  def resize(%Session{id: id}, cols, rows, _opts) do
    GenServer.call(
      server(),
      {:record, id, {:resize, cols, rows}, %{cols: cols, rows: rows}}
    )
  end

  @impl Arbiter.Sessions.Terminal
  def geometry(%Session{id: id}, _opts) do
    state = fetch(id)
    {:ok, %{cols: state.cols, rows: state.rows, title: state.title}}
  end

  @impl Arbiter.Sessions.Terminal
  def alive?(%Session{id: id}, _opts), do: fetch(id).alive?

  # -- server -----------------------------------------------------------------

  defp server do
    case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:install, id, state}, _from, sessions) do
    {:reply, :ok, Map.put(sessions, id, state)}
  end

  def handle_call({:fetch, id}, _from, sessions) do
    {:reply, Map.get(sessions, id, @defaults), sessions}
  end

  def handle_call({:put, id, attrs}, _from, sessions) do
    {:reply, :ok, Map.update(sessions, id, Map.merge(@defaults, attrs), &Map.merge(&1, attrs))}
  end

  def handle_call({:emit, id, bytes}, _from, sessions) do
    state = Map.fetch!(sessions, id)
    File.write!(state.path, bytes, [:append, :binary])
    {:reply, :ok, sessions}
  end

  def handle_call({:start_stream, id, path}, _from, sessions) do
    state = Map.get(sessions, id, @defaults)
    state = %{state | path: path, streaming?: true, calls: [{:start_stream, path} | state.calls]}

    case state.start_stream_result do
      :ok ->
        File.touch!(path)
        {:reply, {:ok, %{snapshot: state.snapshot}}, Map.put(sessions, id, state)}

      {:error, _} = error ->
        {:reply, error, Map.put(sessions, id, state)}
    end
  end

  def handle_call({:send_input, id, bytes}, _from, sessions) do
    state = Map.get(sessions, id, @defaults)

    state = %{
      state
      | input: state.input <> bytes,
        calls: [{:send_input, bytes} | state.calls]
    }

    {:reply, :ok, Map.put(sessions, id, state)}
  end

  def handle_call({:record, id, call, attrs}, _from, sessions) do
    state = Map.get(sessions, id, @defaults)
    state = state |> Map.merge(attrs) |> Map.update!(:calls, &[call | &1])
    {:reply, :ok, Map.put(sessions, id, state)}
  end

  def handle_call({:record_fetch, id, call}, _from, sessions) do
    state = Map.get(sessions, id, @defaults)
    state = Map.update!(state, :calls, &[call | &1])
    {:reply, state, Map.put(sessions, id, state)}
  end
end
