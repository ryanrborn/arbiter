defmodule Arbiter.Sessions.TranscriptRetention do
  @moduledoc """
  Deletes a coordinator session's persisted raw transcript
  (`Arbiter.Sessions.Transcript`) once the session has been `:ended` for
  longer than the retention window (§11, phase 9 of
  `docs/browser-hosted-coordinator-sessions.md`).

  The session's tmux pipe file (`Arbiter.Sessions.Naming.pipe_path/1`) is
  removed alongside the transcript: it lives on tmpfs
  (`$XDG_RUNTIME_DIR/arbiter`), is no longer closed when the last reader
  detaches (`Arbiter.Sessions.Stream`'s moduledoc, bd-5pelo2 finding 1), and
  nothing else ever deletes it — without this sweep an ended session's raw
  PTY bytes would sit in RAM forever (bd-5pelo2 round 4 finding 3). The rest
  of the session's scaffold (`Arbiter.Sessions.Layout`) is a separate concern
  this sweep does not touch. Modelled directly on `Arbiter.Events.Retention`:
  an injectable `:now` and explicit options for tests, a config-backed
  default for production, and a best-effort sweep that logs and swallows
  rather than crashing its caller.

  ## Configuration

  Via `config :arbiter, :sessions_transcript_retention`:

    * `:enabled`         — master switch (default `true`; `false` in test,
                           where tests drive `sweep/1` synchronously).
    * `:interval_ms`     — sweep cadence (default 21_600_000, 6 hours).
    * `:retention_days`  — age past `ended_at` before deletion (default
                           `Arbiter.Sessions.Transcript.retention_days/0`).
    * `:fetch_limit`     — max `:ended` sessions scanned per sweep (default 500).
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Transcript

  @default_interval_ms 6 * 60 * 60_000
  @default_fetch_limit 500

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Delete the transcript file of every `:ended` session whose `ended_at` is
  older than `:retention_days` (default from config, overridable via opts —
  mainly for tests). A session with no captured transcript is a no-op.
  Best-effort: a delete failure is logged and does not stop the sweep.
  """
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []) do
    retention_days =
      Keyword.get(opts, :retention_days, cfg(:retention_days, Transcript.retention_days()))

    fetch_limit = Keyword.get(opts, :fetch_limit, cfg(:fetch_limit, @default_fetch_limit))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -retention_days, :day)

    Session
    |> Ash.Query.filter(status == :ended and not is_nil(ended_at) and ended_at < ^cutoff)
    |> Ash.Query.limit(fetch_limit)
    |> Ash.read!()
    |> Enum.each(&purge_one/1)

    :ok
  rescue
    e ->
      Logger.error("Arbiter.Sessions.TranscriptRetention sweep failed: #{Exception.message(e)}")
      :ok
  end

  defp purge_one(%Session{id: id}) do
    rm_if_exists(Transcript.path_for(id))
    rm_if_exists(Transcript.offset_path_for(id))

    case Naming.pipe_path(id) do
      {:ok, pipe_path} -> rm_if_exists(pipe_path)
      {:error, _reason} -> :ok
    end
  end

  defp rm_if_exists(path) do
    if File.regular?(path) do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Arbiter.Sessions.TranscriptRetention: could not delete #{path}: #{inspect(reason)}"
          )
      end
    end
  end

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_transcript_retention, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
