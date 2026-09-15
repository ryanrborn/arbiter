defmodule Arbiter.Sessions.StreamTest do
  @moduledoc """
  The reader (bd-3ymdvi, phase 4 of
  `docs/browser-hosted-coordinator-sessions.md` §5.3): sequence numbers, the
  bounded replay ring, resume, backpressure, and multi-client fan-out.

  Run headlessly against `Arbiter.Test.ScriptedPty` — a scripted terminal that
  appends to the same kind of file tmux's `pipe-pane` writes, so the byte path
  under test is the real one (AC 7). `Arbiter.Integration.SessionTmuxTest`
  runs the same protocol against a real tmux server.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.ScriptedPty

  @moduletag :tmp_dir

  # Poll fast: every test here is waiting on the reader noticing new bytes.
  @opts [
    terminal: ScriptedPty,
    poll_interval_ms: 5,
    alive_interval_ms: 20,
    linger_ms: 0
  ]

  setup %{tmp_dir: tmp_dir} do
    id = Ash.UUID.generate()
    session = %Session{id: id, tmux_socket: Path.join(tmp_dir, "s.sock")}
    ScriptedPty.install(id, snapshot: "SNAPSHOT", cols: 80, rows: 24, title: "scripted")

    on_exit(fn ->
      Stream.stop(id)
    end)

    %{id: id, session: session, opts: Keyword.put(@opts, :pipe_dir, tmp_dir)}
  end

  defp attach(session, opts, extra \\ []) do
    Stream.attach(session, Keyword.merge(opts, extra))
  end

  defp assert_stdout(id, expected, timeout \\ 1_000) do
    assert_receive {:session_stdout, ^id, frame}, timeout
    assert {:ok, seq, ^expected} = Frame.decode(frame)
    seq
  end

  defp collect_stdout(id, until_bytes, acc \\ <<>>, seq \\ nil) do
    if byte_size(acc) >= until_bytes do
      {acc, seq}
    else
      receive do
        {:session_stdout, ^id, frame} ->
          {:ok, seq, data} = Frame.decode(frame)
          collect_stdout(id, until_bytes, acc <> data, seq)
      after
        2_000 -> {acc, seq}
      end
    end
  end

  describe "attach/2 — first join" do
    test "starts the pipe, returns a snapshot and the current seq", %{
      session: session,
      id: id,
      opts: opts
    } do
      assert {:ok, attached} = attach(session, opts)

      assert attached.mode == :snapshot
      assert attached.snapshot == "SNAPSHOT"
      assert attached.replay == []
      assert attached.seq == 0
      assert attached.meta.cols == 80
      assert attached.meta.rows == 24
      assert attached.meta.title == "scripted"
      assert attached.meta.attached_clients == 1

      assert [{:start_stream, path} | _] = ScriptedPty.calls(id)
      assert Path.basename(path) == "session-#{id}.out"
    end

    test "leaves no long-lived handle on the terminal — only the pipe file", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      pid = Stream.whereis(id)

      # The reader owns exactly one fd, on an ordinary file. Not a port.
      assert Process.info(pid, :links) |> elem(1) |> Enum.filter(&is_port/1) == []
    end

    test "streams bytes the pane produces, framed with a monotonic seq", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)

      ScriptedPty.emit(id, "hello")
      assert assert_stdout(id, "hello") == 5

      ScriptedPty.emit(id, " world")
      assert assert_stdout(id, " world") == 11
    end

    test "seq is the byte offset of the last byte in the frame", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)

      ScriptedPty.emit(id, :binary.copy("x", 1000))
      {data, seq} = collect_stdout(id, 1000)

      assert byte_size(data) == 1000
      assert seq == 1000
    end

    test "passes bytes through untouched — split UTF-8 and split ANSI (AC 1)", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)

      <<rocket_head::binary-size(2), rocket_tail::binary>> = "🚀"
      escape = <<0x1B, ?[, ?1, ?;, ?3, ?1, ?m>>
      <<esc_head::binary-size(2), esc_tail::binary>> = escape

      # Each half arrives in its own poll tick, i.e. its own frame.
      ScriptedPty.emit(id, rocket_head)
      assert_stdout(id, rocket_head)
      ScriptedPty.emit(id, rocket_tail)
      assert_stdout(id, rocket_tail)
      ScriptedPty.emit(id, esc_head)
      assert_stdout(id, esc_head)
      ScriptedPty.emit(id, esc_tail)
      assert_stdout(id, esc_tail)
    end

    test "does not replay bytes the snapshot already covers (§4.5 overlap seam)", %{
      session: session,
      id: id,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      # Bytes produced while nobody was watching are in the pipe file already.
      path = Path.join(tmp_dir, "session-#{id}.out")
      File.write!(path, "OLD OUTPUT")
      ScriptedPty.put(id, path: path)

      {:ok, attached} = attach(session, opts)
      assert attached.seq == 10

      ScriptedPty.emit(id, "NEW")
      assert assert_stdout(id, "NEW") == 13
    end
  end

  describe "coalescing (§5.3 item 1)" do
    test "bytes that arrive between polls are concatenated into one frame", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, Keyword.put(opts, :poll_interval_ms, 60))

      ScriptedPty.emit(id, "a")
      ScriptedPty.emit(id, "b")
      ScriptedPty.emit(id, "c")

      assert_stdout(id, "abc")
    end
  end

  describe "resume (AC 3)" do
    test "a valid last_seq replays exactly the missed frames in order", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, Keyword.put(opts, :poll_interval_ms, 60))
      ScriptedPty.emit(id, "one")
      assert assert_stdout(id, "one") == 3

      # A second client joins from seq 3 after three more frames land.
      ScriptedPty.emit(id, "two")
      assert_stdout(id, "two")
      ScriptedPty.emit(id, "three")
      assert_stdout(id, "three")

      client = spawn_client()
      {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 3)

      assert attached.mode == :resumed
      assert attached.snapshot == nil
      assert attached.seq == 11

      assert Enum.map(attached.replay, &Frame.decode/1) == [
               {:ok, 6, "two"},
               {:ok, 11, "three"}
             ]
    end

    test "a last_seq mid-frame replays only the tail of that frame", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, Keyword.put(opts, :poll_interval_ms, 60))
      ScriptedPty.emit(id, "abcdef")
      assert_stdout(id, "abcdef")

      client = spawn_client()
      {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 2)

      assert attached.mode == :resumed
      assert Enum.map(attached.replay, &Frame.decode/1) == [{:ok, 6, "cdef"}]
    end

    test "last_seq equal to the head resumes with nothing to replay", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      ScriptedPty.emit(id, "abc")
      assert_stdout(id, "abc")

      client = spawn_client()
      assert {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 3)
      assert attached.mode == :resumed
      assert attached.replay == []
    end

    test "an out-of-range last_seq falls back to a snapshot", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      ScriptedPty.emit(id, "abc")
      assert_stdout(id, "abc")

      client = spawn_client()

      # Ahead of the stream — a client from a previous, longer-lived reader.
      assert {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 9_999)
      assert attached.mode == :snapshot
      assert attached.snapshot == "SNAPSHOT"
      assert attached.seq == 3
    end

    test "a gap larger than the replay window falls back to a snapshot", %{
      session: session,
      id: id,
      opts: opts
    } do
      opts = Keyword.merge(opts, ring_bytes: 128, max_replay_bytes: 128)
      {:ok, _} = attach(session, opts)

      ScriptedPty.emit(id, :binary.copy("z", 4_000))
      {_data, _seq} = collect_stdout(id, 4_000)

      client = spawn_client()
      assert {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 0)
      assert attached.mode == :snapshot
    end

    test "resume beyond the in-memory ring is served from the pipe file", %{
      session: session,
      id: id,
      opts: opts
    } do
      # Ring far smaller than the replay window: the ring cannot answer, the
      # file can, and the client must still get its bytes rather than a repaint.
      opts = Keyword.merge(opts, ring_bytes: 64, max_replay_bytes: 1_000_000)
      {:ok, _} = attach(session, opts)

      ScriptedPty.emit(id, :binary.copy("q", 4_000))
      {_data, _seq} = collect_stdout(id, 4_000)

      client = spawn_client()
      {:ok, attached} = attach(session, opts, subscriber: client, last_seq: 100)

      assert attached.mode == :resumed
      assert attached.seq == 4_000

      replayed =
        attached.replay
        |> Enum.map(fn frame ->
          {:ok, _seq, data} = Frame.decode(frame)
          data
        end)
        |> IO.iodata_to_binary()

      assert replayed == :binary.copy("q", 3_900)
    end
  end

  describe "ring bound (§5.3)" do
    test "the replay ring stays inside its configured byte budget", %{
      session: session,
      id: id,
      opts: opts
    } do
      opts = Keyword.put(opts, :ring_bytes, 4_096)
      {:ok, _} = attach(session, opts)

      for _ <- 1..40, do: ScriptedPty.emit(id, :binary.copy("y", 1_024))
      {_data, _seq} = collect_stdout(id, 40_960)

      stats = Stream.stats(id)
      assert stats.ring_bytes <= 4_096
      assert stats.seq == 40_960
      assert stats.ring_base >= 40_960 - 4_096
    end
  end

  describe "backpressure (AC 4, §5.3 item 2)" do
    test "a consumer that never acks is cut off at the high-water mark", %{
      session: session,
      id: id,
      opts: opts
    } do
      opts = Keyword.merge(opts, high_water_bytes: 4_096, read_chunk_bytes: 1_024)
      slow = spawn_silent_client()
      {:ok, _} = attach(session, opts, subscriber: slow)

      for _ <- 1..64, do: ScriptedPty.emit(id, :binary.copy("s", 1_024))

      # Give the reader ample time to drain the file into a client that is
      # not reading: if it did so unboundedly, the mailbox would hold 64 KB.
      wait_until(fn -> Stream.stats(id).seq >= 65_536 end)

      queued = mailbox_bytes(slow)

      assert queued <= 4_096 + 1_024 + Frame.header_size(),
             "slow client mailbox grew to #{queued} bytes, past the 4 KB high-water mark"

      assert Stream.stats(id).subscribers |> hd() |> Map.get(:mode) == :dropping
    end

    test "the reader's own mailbox and memory stay bounded", %{
      session: session,
      id: id,
      opts: opts
    } do
      opts = Keyword.merge(opts, high_water_bytes: 4_096, ring_bytes: 8_192)
      slow = spawn_silent_client()
      {:ok, _} = attach(session, opts, subscriber: slow)

      for _ <- 1..128, do: ScriptedPty.emit(id, :binary.copy("s", 8_192))
      wait_until(fn -> Stream.stats(id).seq >= 1_048_576 end, 5_000)

      pid = Stream.whereis(id)
      {:message_queue_len, queue} = Process.info(pid, :message_queue_len)
      {:memory, memory} = Process.info(pid, :memory)

      assert queue <= 10
      assert memory <= 1_000_000, "reader heap grew to #{memory} bytes on a 1 MB stream"
    end

    test "a recovered consumer is repainted with a snapshot and resumes live", %{
      session: session,
      id: id,
      opts: opts
    } do
      opts = Keyword.merge(opts, high_water_bytes: 2_048, read_chunk_bytes: 1_024)
      {:ok, _} = attach(session, opts)

      for _ <- 1..16, do: ScriptedPty.emit(id, :binary.copy("s", 1_024))
      wait_until(fn -> Stream.stats(id).seq >= 16_384 end)
      assert Stream.stats(id).subscribers |> hd() |> Map.get(:mode) == :dropping

      ScriptedPty.put(id, snapshot: "REPAINT")
      Stream.ack(id, 1_000_000)

      assert_receive {:session_snapshot, ^id, %{data: "REPAINT", seq: seq}}, 1_000
      assert seq >= 16_384

      flush_stdout()
      ScriptedPty.emit(id, "after")
      assert_stdout(id, "after")
    end
  end

  describe "multi-client (AC 5)" do
    test "two clients receive the same stream", %{session: session, id: id, opts: opts} do
      {:ok, _} = attach(session, opts)
      second = spawn_client()
      {:ok, _} = attach(session, opts, subscriber: second)

      ScriptedPty.emit(id, "shared")

      assert_stdout(id, "shared")
      assert_receive {:client_got, ^second, {:session_stdout, ^id, frame}}, 1_000
      assert {:ok, 6, "shared"} = Frame.decode(frame)
    end

    test "a resize by one client yields meta to the other", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      second = spawn_client()
      {:ok, _} = attach(session, opts, subscriber: second)

      # Joining already told everyone the client count changed.
      assert_receive {:session_meta, ^id, %{attached_clients: 2}}, 1_000

      assert :ok = Stream.resize(id, 132, 43, second)

      assert_receive {:session_meta, ^id, meta}, 1_000
      assert meta.cols == 132
      assert meta.rows == 43
      assert meta.attached_clients == 2

      assert_receive {:client_got, ^second, {:session_meta, ^id, %{cols: 132}}}, 1_000
      assert {:resize, 132, 43} in ScriptedPty.calls(id)
    end

    test "last writer wins — the most recent resize is the pane size", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      second = spawn_client()
      {:ok, _} = attach(session, opts, subscriber: second)

      :ok = Stream.resize(id, 100, 30, self())
      :ok = Stream.resize(id, 200, 60, second)

      assert Stream.stats(id).cols == 200
      assert Stream.stats(id).rows == 60
    end

    test "detaching one client leaves the other streaming", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      second = spawn_client()
      {:ok, _} = attach(session, opts, subscriber: second)

      :ok = Stream.detach(id, second)

      assert_receive {:session_meta, ^id, %{attached_clients: 1}}, 1_000
      assert Stream.whereis(id)

      ScriptedPty.emit(id, "still here")
      assert_stdout(id, "still here")
    end

    test "a client that dies is dropped without taking the reader with it", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      second = spawn_client()
      {:ok, _} = attach(session, opts, subscriber: second)

      ref = Process.monitor(second)
      Process.exit(second, :kill)
      assert_receive {:DOWN, ^ref, :process, ^second, :killed}

      assert_receive {:session_meta, ^id, %{attached_clients: 1}}, 1_000
      assert Stream.whereis(id)
    end
  end

  describe "detach (AC 2)" do
    test "the last detach drops the reader and closes the pipe, not the session", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      pid = Stream.whereis(id)
      ref = Process.monitor(pid)

      :ok = Stream.detach(id, self())

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      # The Registry drops the entry when it handles the reader's DOWN, which
      # is not ordered against *our* DOWN.
      wait_until(fn -> Stream.whereis(id) == nil end)

      # The pipe was closed; nothing killed the terminal.
      assert {:stop_stream} in ScriptedPty.calls(id)
      assert ScriptedPty.fetch(id).alive?
    end

    test "reattaching after a detach continues the same seq space", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      ScriptedPty.emit(id, "before")
      assert assert_stdout(id, "before") == 6

      :ok = Stream.detach(id, self())
      wait_until(fn -> Stream.whereis(id) == nil end)

      # Output produced while detached lands in the pipe file, and is covered
      # by the snapshot rather than replayed as frames (§4.5).
      ScriptedPty.emit(id, "while away")

      {:ok, attached} = attach(session, opts)
      assert attached.seq == 16

      ScriptedPty.emit(id, "!")
      assert assert_stdout(id, "!") == 17
    end
  end

  describe "reader lifecycle races" do
    test "reattaching the instant the previous reader stops always succeeds", %{
      session: session,
      id: id,
      opts: opts
    } do
      # A browser reload, or a second tab opening as the first closes: the
      # registry entry for a reader outlives its reply by however long the
      # Registry takes to handle the DOWN, so `attach/2` can resolve a pid that
      # is already terminating and the call to it exits `:noproc`.
      #
      # A stress test rather than a deterministic one — the window is the
      # registry's handling of a single `:DOWN` and cannot be opened on demand
      # — so it is run from several processes at once to widen it, and every
      # attach must still come back `{:ok, _}` rather than an exit.
      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            for _ <- 1..15 do
              {:ok, _attached} = attach(session, opts)
              :ok = Stream.detach(id, self())
            end

            :done
          end)
        end

      assert Enum.map(tasks, &Task.await(&1, 30_000)) == List.duplicate(:done, 8)

      assert {:ok, attached} = attach(session, opts)
      assert attached.meta.attached_clients == 1
    end
  end

  describe "input" do
    test "types raw bytes into the pane", %{session: session, id: id, opts: opts} do
      {:ok, _} = attach(session, opts)

      assert :ok = Stream.input(id, <<0x1B, ?[, ?A>>, self())
      assert :ok = Stream.input(id, "ls\r", self())

      assert ScriptedPty.input(id) == <<0x1B, ?[, ?A, ?l, ?s, ?\r>>
    end

    test "is refused from a process that is not attached", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      stranger = spawn_client()

      assert {:error, :not_attached} = Stream.input(id, "rm -rf /\r", stranger)
      assert ScriptedPty.input(id) == <<>>
    end
  end

  describe "exit (AC 6)" do
    test "an exited session yields an exit event and stops the reader", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, opts)
      pid = Stream.whereis(id)
      ref = Process.monitor(pid)

      ScriptedPty.emit(id, "last gasp")
      assert_stdout(id, "last gasp")
      ScriptedPty.put(id, alive?: false)

      assert_receive {:session_exit, ^id, %{code: nil, reason: "exited"}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "output written just before the exit is drained first", %{
      session: session,
      id: id,
      opts: opts
    } do
      {:ok, _} = attach(session, Keyword.put(opts, :poll_interval_ms, 1_000))

      ScriptedPty.emit(id, "goodbye")
      ScriptedPty.put(id, alive?: false)

      assert_stdout(id, "goodbye", 2_000)
      assert_receive {:session_exit, ^id, _}, 2_000
    end
  end

  describe "attach failures" do
    test "a terminal that cannot start a stream reports the error", %{
      session: session,
      id: id,
      opts: opts
    } do
      ScriptedPty.put(id, start_stream_result: {:error, {:tmux_failed, 1, "no server running"}})

      assert {:error, {:tmux_failed, 1, "no server running"}} = attach(session, opts)
      wait_until(fn -> Stream.whereis(id) == nil end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # A client that forwards everything it is sent back to the test, so a second
  # subscriber's traffic can be asserted from here.
  defp spawn_client do
    test = self()

    pid =
      spawn(fn ->
        forward = fn forward ->
          receive do
            msg ->
              send(test, {:client_got, self(), msg})
              forward.(forward)
          end
        end

        forward.(forward)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # A client that never reads its mailbox and never acks — the slow consumer.
  defp spawn_silent_client do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp flush_stdout do
    receive do
      {:session_stdout, _id, _frame} -> flush_stdout()
    after
      0 -> :ok
    end
  end

  defp mailbox_bytes(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.reduce(messages, 0, fn
      {:session_stdout, _id, frame}, acc -> acc + byte_size(frame)
      _, acc -> acc
    end)
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within the deadline")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
