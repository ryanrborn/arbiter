defmodule ArbiterWeb.SessionDockTerminalBrowserTest do
  @moduledoc """
  The session dock's terminal, end to end (bd-9myzv8, phase 2 of the session
  dock epic).

  `ArbiterWeb.SessionDockLiveTest` proves everything the server decides: that
  the expanded window renders the hook, that the collapsed ones do not, and
  that exactly one pane exists across a full strip. Every remaining acceptance
  criterion is a claim about the *client*, and `Phoenix.LiveViewTest` has no
  client, no xterm and no second socket to lose:

    * expanding connects to `/session` and resumes from the last seen
      `last_seq`, so output produced while the window was collapsed appears
      with nothing lost and nothing duplicated;
    * collapsing disposes the xterm and closes the socket, so a strip of
      collapsed windows holds zero of each — asserted from *both* ends, the
      browser counting `.xterm` nodes and this process counting the readers
      actually attached;
    * at most one xterm and one `/session` connection exists whatever the
      number of open windows;
    * navigating between pages keeps the terminal connected and correctly laid
      out, with no repaint — the epic's headline behaviour;
    * the geometry is right on expand, after a browser resize, and after the
      re-parent a live navigation puts the sticky dock through;
    * `Ctrl/Cmd+Shift+Escape` hands the keyboard back to the page;
    * a LiveView rejoin — a server restart, §10.1's whole point — comes back
      to a live, fitted terminal rather than an empty strip.

  ## The handshake

  Producing output *while a window is collapsed* is the one thing neither side
  can do alone: the browser has no terminal to type into, and this process
  cannot see the strip. So `scripts/verify_session_dock_terminal.mjs` and the
  `Task` below take turns over two files in `tmp_dir` — the script writes
  `req` as `<n> <command>`, this side answers in `ack` as `<n> <result>`.
  `subscribers` is answered from `Arbiter.Sessions.Stream.stats/1`, which is
  how "zero live sockets" is checked against the server rather than inferred
  from the DOM.

  The pane is `Arbiter.Test.ScriptedPty`, so `emit` appends raw bytes to the
  same pipe file tmux's `pipe-pane` writes: the reader, the framing, the ring
  and the resume arithmetic are all the real ones.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the session rows, and the listener binds a real port.
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Test.ScriptedPty

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_session_dock_terminal.mjs"

  @listener_id :session_dock_terminal_listener

  setup %{tmp_dir: tmp_dir} do
    Arbiter.Test.SessionEnv.sandbox("session-dock-terminal")
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_terminal, ScriptedPty)
    put_env(:sessions_runner, NoopRunner)

    # A brisk reader: the browser is waiting on every byte this test emits.
    put_env(Arbiter.Sessions.Stream, poll_interval_ms: 5, alive_interval_ms: 50)
    :ok
  end

  test "the dock's terminal survives navigation and resumes across a collapse",
       %{tmp_dir: tmp_dir} do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    a = launch!(tmp_dir, "alpha")
    b = launch!(tmp_dir, "beta")

    case build_assets() do
      :ok -> drive(node, tmp_dir, a, b)
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # `put/2`, not `install/2`. `Sessions.launch/1` starts §11's transcript
  # reader eagerly (`ensure_reader`), and that reader calls `start_stream/3`
  # from its own `handle_continue` — so it races anything scripted here.
  # `install/2` *resets* the scripted state, which every so often landed after
  # the reader and wiped the pipe path out from under it; `put/2` merges.
  defp launch!(tmp_dir, name) do
    {:ok, session} = Sessions.launch(cwd: tmp_dir, name: name, runner: NoopRunner)

    ScriptedPty.put(session.id, snapshot: "-- #{name} --", cols: 80, rows: 24, title: name)

    on_exit(fn -> Stream.stop(session.id) end)
    session
  end

  defp drive(node, tmp_dir, a, b) do
    port = start_listener!()
    sync = Path.join(tmp_dir, "sync")
    File.mkdir_p!(sync)

    responder = Task.async(fn -> respond(sync) end)

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the socket's Origin
        # against the endpoint's configured host, and a browser sends the one
        # it was pointed at.
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--seconds",
          "30",
          "--session-a",
          a.id,
          "--session-b",
          b.id,
          "--sync",
          sync
        ] ++ screenshot_args(),
        cd: @root,
        stderr_to_stdout: true
      )

    File.write!(Path.join(sync, "stop"), "stop")
    Task.await(responder, 30_000)

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_session_dock_terminal.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

        # Named one by one as well as by the verdict: a check that quietly
        # stops being emitted still leaves a green `RESULT: PASS` behind, and
        # these are the acceptance criteria themselves.
        for claim <- [
              "expanding-a-window-connects-that-session",
              "the-expanded-window-fits-a-usable-terminal",
              "the-fitted-geometry-reaches-the-pane",
              "navigating-does-not-re-mount-the-terminal",
              "navigating-keeps-the-terminal-connected",
              "navigating-keeps-the-geometry-with-no-repaint",
              "navigating-keeps-the-scrollback",
              "output-keeps-arriving-after-the-navigation",
              "a-liveview-rejoin-comes-back-to-a-live-fitted-terminal",
              "at-most-one-xterm-and-one-socket-whatever-is-open",
              "collapsing-tears-down-the-xterm-and-closes-the-socket",
              "expanding-replays-what-the-window-missed-exactly-once",
              "expanding-resumes-rather-than-replaying-the-whole-stream",
              "the-resumed-window-is-laid-out-correctly",
              "a-browser-resize-refits-and-tells-the-pane",
              "a-strip-layout-change-refits-the-terminal-down-to-the-80-column-floor",
              "ctrl-shift-escape-hands-the-keyboard-back-to-the-page",
              "no-console-errors"
            ] do
          assert output =~ "CHECK #{claim}: PASS", "the browser never reported #{claim}"
        end

        # Neither session was killed or detached by any of it: the dock is a
        # view onto a session, never a lifecycle control (phase 3 changes that
        # deliberately, not by accident here).
        assert {:ok, %{status: :running, ended_at: nil}} = Sessions.get(a.id)
        assert {:ok, %{status: :running, ended_at: nil}} = Sessions.get(b.id)

      _other ->
        flunk("verify_session_dock_terminal.mjs failed:\n\n#{output}")
    end
  end

  # -- the handshake ----------------------------------------------------------

  # One turn at a time, oldest request first. It exits on the `stop` file the
  # test drops once the script has finished, so a script that dies early never
  # leaves this polling forever.
  defp respond(sync, seen \\ 0) do
    req = Path.join(sync, "req")

    cond do
      File.exists?(Path.join(sync, "stop")) ->
        :done

      true ->
        case File.read(req) do
          {:ok, raw} ->
            [n | words] = raw |> String.trim() |> String.split(" ")
            n = String.to_integer(n)

            if n > seen do
              File.write!(Path.join(sync, "ack"), "#{n} #{handle(words)}")
              respond(sync, n)
            else
              Process.sleep(25)
              respond(sync, seen)
            end

          {:error, _} ->
            Process.sleep(25)
            respond(sync, seen)
        end
    end
  end

  # `emit <session-id> <text>` — the pane prints a line, exactly as tmux's
  # `pipe-pane … cat >> path` would.
  defp handle(["emit", session_id, text]) do
    case await_pipe(session_id) do
      :ok ->
        ScriptedPty.emit(session_id, text <> "\r\n")
        "ok"

      :error ->
        # Reported rather than raised: a crashed responder takes the handshake
        # with it and the script's failure becomes a timeout with no reason in
        # it. This way the browser prints why.
        "no-pipe-for-#{session_id}"
    end
  end

  # `subscribers <id> <id> …` — how many readers each session actually has.
  # This is the server-side half of "collapsing closes the socket": a browser
  # can only say that it holds no xterm.
  defp handle(["subscribers" | ids]) do
    ids |> Enum.map(&subscriber_count/1) |> Enum.join(" ")
  end

  defp handle(other), do: "unknown-command:#{Enum.join(other, " ")}"

  # The reader opens the pipe from its own process, so "the session is live in
  # the browser" and "there is a file to append to" are not the same instant.
  defp await_pipe(session_id, attempts \\ 100) do
    cond do
      ScriptedPty.path(session_id) != nil -> :ok
      attempts == 0 -> :error
      true -> Process.sleep(25) && await_pipe(session_id, attempts - 1)
    end
  end

  defp subscriber_count(session_id) do
    case Stream.stats(session_id) do
      %{subscribers: subscribers} -> length(subscribers)
      nil -> 0
    end
  end

  # -- the listener -----------------------------------------------------------

  # The same two commands `mix assets.build` runs, called in-process — never by
  # shelling out to `mix`, which would deadlock on the build lock the
  # surrounding `mix test` already holds.
  defp build_assets do
    cond do
      not (Code.ensure_loaded?(Esbuild) and Code.ensure_loaded?(Tailwind)) ->
        {:skipped, "the esbuild/tailwind Mix packages are not loadable"}

      not (File.exists?(Esbuild.bin_path()) and File.exists?(Tailwind.bin_path())) ->
        {:skipped, "no esbuild/tailwind binary on disk — run `mix assets.setup`"}

      Tailwind.run(:arbiter_web, []) != 0 or Esbuild.run(:arbiter_web, []) != 0 ->
        flunk("the asset build failed")

      true ->
        :ok
    end
  end

  defp screenshot_args do
    case System.get_env("ARB_DOCK_SCREENSHOT") do
      nil -> []
      path -> ["--screenshot", path]
    end
  end

  # `port: 0` lets the kernel pick and we read the bound port back off Thousand
  # Island, so a sibling VM on this host can never lose a race for a port we
  # probed for and had not yet bound.
  defp start_listener! do
    listener =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
          id: @listener_id
        )
      )

    {:ok, {_address, bound}} = ThousandIsland.listener_info(listener)
    bound
  end
end
