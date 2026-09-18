defmodule Arbiter.Sessions.TranscriptReplay do
  @moduledoc """
  Reading a finished session's persisted raw transcript back (bd-3tf4oo).

  `Arbiter.Sessions.Transcript` writes `<sessions_root>/<id>/transcript/<id>.raw`
  while a session is alive; this is the only thing that reads it for display.
  It answers two questions and nothing else:

    * `describe/2` — *is* there a transcript for this session, how big is it,
      how much of it would a replay show, and if there is none, **why**. The
      dock renders an honest state from this, never a blank terminal.
    * `read_tail/2` — the bytes themselves, bounded: the last `max_bytes` of
      the file, verbatim, ANSI included. `ArbiterWeb.SessionChannel` pushes
      exactly these bytes as the same `snapshot` event a live attach sends,
      so the browser paints a finished session through the live terminal's
      own repaint path rather than through a second renderer.

  ## Why "unavailable" has a reason

  A missing file is not one situation:

    * `:retention_deleted` — the session ended longer ago than
      `Arbiter.Sessions.Transcript.retention_days/0`, so
      `Arbiter.Sessions.TranscriptRetention` has swept it. The operator's
      transcript is gone on purpose and no amount of retrying brings it back.
    * `:never_captured` — the session ended inside the retention window with
      no file at all: it predates transcript persistence (bd-5pelo2, phase 9),
      or its reader never started.
    * `:empty` — the file exists but holds nothing. A pane that produced no
      bytes is not a transcript, and replaying zero bytes into a terminal is
      the blank screen this ticket exists to remove.

  The split is made from `ended_at` against the retention window rather than
  from any marker on disk, because the sweep deletes the offset sidecar with
  the transcript (`TranscriptRetention.purge_one/1`) — after it runs there is
  nothing left to distinguish the two.

  ## The cap

  A transcript can reach `Transcript.max_bytes/0` (100 MB). Pushing that down
  a channel and into xterm is not a display, it is an outage, so a replay
  shows the **tail**: the last `max_bytes/0` bytes (default 256 KB), with
  `truncated?` and the byte figures for the UI to say "showing last N of M"
  and offer the whole file as a download.

  A tail starts at an arbitrary byte, which can land mid-UTF-8. Leading
  continuation bytes are dropped so xterm is never handed a broken code
  point; nothing else is touched — a cut can still land inside an escape
  sequence, which costs at most the styling of the first line and is why the
  UI says the view is truncated.

  ## Configuration

  Via `config :arbiter, :sessions_transcript`:

    * `:replay_max_bytes` — bytes a replay shows (default 262_144, 256 KB).
  """

  alias Arbiter.Sessions.Transcript
  alias Arbiter.Worker.SessionArchive

  @default_replay_max_bytes 256 * 1024

  @typedoc "Why a session has no transcript to show."
  @type reason :: :retention_deleted | :never_captured | :empty

  @typedoc """
  What the UI needs to decide between a replay and an honest empty state.

  `replay_bytes` is what a replay would actually paint — the whole file, or
  `max_bytes` of tail when `truncated?`.
  """
  @type description :: %{
          available?: boolean(),
          reason: reason() | nil,
          path: String.t(),
          total_bytes: non_neg_integer(),
          replay_bytes: non_neg_integer(),
          truncated?: boolean(),
          archived?: boolean()
        }

  @type tail :: %{
          data: binary(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          total_bytes: non_neg_integer(),
          truncated?: boolean()
        }

  @doc "Bytes a replay paints before it is a tail rather than the whole file."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: cfg(:replay_max_bytes, @default_replay_max_bytes)

  @doc """
  Whether `session` has a transcript to replay, and if not, why not.

  Takes a `Arbiter.Sessions.Session` or any map carrying `:id` and
  `:ended_at` — the dock passes rows straight in. A session id on its own is
  accepted too, and is then treated as having ended just now (no `ended_at`
  means the retention sweep cannot have run for it yet).

  ## Options

    * `:max_bytes` — override the replay cap, for tests and for a caller that
      wants a different bound than the channel's.
  """
  @spec describe(map() | String.t(), keyword()) :: description()
  def describe(session, opts \\ [])

  def describe(id, opts) when is_binary(id), do: describe(%{id: id, ended_at: nil}, opts)

  def describe(%{id: id} = session, opts) when is_binary(id) and id != "" do
    cap = Keyword.get(opts, :max_bytes, max_bytes())
    path = Transcript.path_for(id)
    total = file_size(path)

    base = %{
      path: path,
      total_bytes: total,
      archived?: SessionArchive.archived?(id)
    }

    cond do
      total > 0 ->
        Map.merge(base, %{
          available?: true,
          reason: nil,
          replay_bytes: min(total, cap),
          truncated?: total > cap
        })

      File.regular?(path) ->
        unavailable(base, :empty)

      swept?(session) ->
        unavailable(base, :retention_deleted)

      true ->
        unavailable(base, :never_captured)
    end
  end

  @doc """
  The last `max_bytes` of `id`'s transcript, verbatim.

  `{:error, :enoent}` when there is nothing to read — the caller has already
  asked `describe/2` and is racing the retention sweep, which is exactly the
  case that must not turn into a blank terminal.

  ## Options

    * `:max_bytes` — how many bytes of tail to read (default `max_bytes/0`).
  """
  @spec read_tail(String.t(), keyword()) :: {:ok, tail()} | {:error, term()}
  def read_tail(id, opts \\ []) when is_binary(id) and id != "" do
    cap = Keyword.get(opts, :max_bytes, max_bytes())
    path = Transcript.path_for(id)

    with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        total = file_size(path)
        start = max(total - cap, 0)

        case read_from(fd, start, total - start) do
          {:ok, data} ->
            data = if start > 0, do: trim_continuation(data), else: data

            {:ok,
             %{
               data: data,
               start_offset: total - byte_size(data),
               end_offset: total,
               total_bytes: total,
               truncated?: start > 0
             }}

          {:error, reason} ->
            {:error, reason}
        end
      after
        :file.close(fd)
      end
    end
  end

  # -- internals ---------------------------------------------------------------

  defp unavailable(base, reason) do
    Map.merge(base, %{
      available?: false,
      reason: reason,
      replay_bytes: 0,
      truncated?: false
    })
  end

  # `eof` from a zero-length read is not a failure: an empty tail is an empty
  # binary, and `describe/2` has already called that case unavailable.
  defp read_from(_fd, _start, 0), do: {:ok, ""}

  defp read_from(fd, start, length) do
    case :file.pread(fd, start, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # A tail can begin in the middle of a multi-byte code point. The
  # continuation bytes (0b10xxxxxx) at the front are the broken half of a
  # character whose lead byte is in the part that was cut off.
  defp trim_continuation(<<0b10::2, _rest_of_byte::6, rest::binary>>),
    do: trim_continuation(rest)

  defp trim_continuation(data), do: data

  # "Ended longer ago than the retention window" — the one case where a
  # missing file is a deletion rather than a capture that never happened.
  defp swept?(%{ended_at: %DateTime{} = ended_at}) do
    cutoff = DateTime.add(DateTime.utc_now(), -Transcript.retention_days(), :day)
    DateTime.compare(ended_at, cutoff) == :lt
  end

  defp swept?(_session), do: false

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_transcript, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
