defmodule ArbiterWeb.SessionTerminalBrowserTest do
  @moduledoc """
  The claims that only a real browser can settle (bd-c76fu9, phase 5
  acceptance criteria 2, 5 and 6).

  It also covers bd-14b11h's remount: mount -> dispose -> mount on a pane that
  has no box yet, which is what a LiveView navigation back to /sessions/<id>
  does, and which used to join at xterm's 80x24 default and garble the pane.

  And, since bd-9myzv8, the session dock's collapse/expand cycle: the resume
  point handed back into a *fresh* terminal, the redraw a replayed delta needs
  because there is no screen under it, the scroll offset a sticky re-parent
  zeroes, and the `Ctrl/Cmd+Shift+Escape` way out of a pane that otherwise
  takes every key.

  `mix test` covers the page chrome, the channel and the resume protocol;
  `ArbiterWeb.SessionTransportSocketTest` covers resume over a real socket.
  None of that touches a renderer. This shells out to
  `scripts/verify_session_terminal.mjs`, which bundles the real
  `createSessionTerminal` with esbuild and drives it inside a headless
  Chromium over the DevTools Protocol.

  What it is really guarding is the vendoring decision. `@xterm/addon-canvas`
  reaches deep into `terminal._core`, so "canvas renders at the versions we
  pinned" is a claim about two minified blobs on disk, and the only way to
  make it is to construct them. It also pins the §6.3 interaction details that
  are easy to get subtly wrong and invisible when wrong: a UTF-8 character
  split across two frames, `Ctrl/Cmd+Shift+C/V`, and — the papercut the whole
  binding exists for — plain `Ctrl+C` still arriving as SIGINT.

  Skipped, not failed, where there is no Chromium or no esbuild on disk: the
  script exits `3` and says so. No npm is involved either way (RFC §6.1).
  """
  use ExUnit.Case, async: true

  @moduletag :browser
  # Bundling plus a browser launch is slower than an ExUnit default allows.
  @moduletag timeout: 180_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_session_terminal.mjs"

  test "the vendored xterm renders on canvas and honours the §6.3 key bindings" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    {output, status} = System.cmd(node, [@script], cd: @root, stderr_to_stdout: true)

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_session_terminal.mjs ---\n" <> output)
    end

    case status do
      3 ->
        # No browser or no esbuild on this machine. Reported, never silently
        # passed: a green check that ran nothing is worse than a skip.
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        assert output =~ "CHECK canvas-renderer: PASS"
        assert output =~ "CHECK binary-write: PASS"
        assert output =~ "CHECK split-utf8-reassembled: PASS"
        assert output =~ "CHECK plain-ctrl-c-is-still-sigint: PASS"

        # bd-14b11h: the LiveView navigation remount. It needs a real layout
        # engine to produce the 0x0 pane, a real xterm to have a construction
        # default to fall back to, and a real frame loop to settle — so this is
        # the only place the claim can be made.
        assert output =~ "CHECK remount-waits-for-a-box-before-joining: PASS"
        assert output =~ "CHECK remount-joins-with-the-fitted-geometry-not-xterms-default: PASS"
        assert output =~ "CHECK remount-renders-at-the-fitted-geometry: PASS"
        assert output =~ "CHECK remount-sends-its-geometry-to-the-pane: PASS"
        assert output =~ "CHECK a-join-that-resized-the-pane-forces-a-redraw: PASS"
        assert output =~ "CHECK a-window-resize-refits-and-tells-the-pane: PASS"
        assert output =~ "CHECK a-tab-that-never-paints-still-attaches: PASS"

        # bd-9myzv8: the session dock's collapse/expand cycle. Destroying and
        # rebuilding the terminal on every expand is the phase's whole design,
        # and three things have to survive it — the resume point, the screen
        # the replayed delta needs under it, and the scroll offset a sticky
        # re-parent zeroes — plus the keyboard rule that makes an expanded
        # terminal escapable.
        assert output =~ "CHECK expand-resumes-from-the-remembered-offset: PASS"
        assert output =~ "CHECK a-resumed-join-onto-a-fresh-terminal-forces-a-redraw: PASS"
        assert output =~ "CHECK a-plain-escape-reaches-the-agent: PASS"

        assert output =~
                 "CHECK ctrl-shift-escape-releases-focus-and-never-reaches-the-agent: PASS"

        assert output =~ "CHECK releasing-focus-really-blurs-the-terminal: PASS"
        assert output =~ "CHECK a-reparent-does-not-leave-the-terminal-scrolled-to-the-top: PASS"
        assert output =~ "CHECK collapsing-tears-down-the-xterm-and-closes-the-socket: PASS"

        # bd-4tjw34: two clients, one pane. The policy is unit-tested under
        # `node --test`; what needs a browser is that it lands on the *real*
        # xterm — that the adopted geometry is what the renderer draws at, and
        # that a real `focusin` is what takes the pane back.
        assert output =~ "CHECK this-clients-own-geometry-is-not-reported-as-adopted: PASS"
        assert output =~ "CHECK another-clients-geometry-is-adopted-by-the-real-xterm: PASS"
        assert output =~ "CHECK the-adopted-geometry-is-labelled-as-adopted: PASS"
        assert output =~ "CHECK the-adopted-screen-renders-without-wrapping: PASS"
        assert output =~ "CHECK a-meta-is-never-answered-with-a-resize: PASS"
        assert output =~ "CHECK focus-reclaims-the-pane-at-this-clients-own-geometry: PASS"
        assert output =~ "CHECK reclaiming-puts-the-real-xterm-back-at-its-own-geometry: PASS"
        assert output =~ "CHECK a-browser-resize-reclaims-an-adopted-pane: PASS"

        refute output =~ ": FAIL"

      other ->
        flunk("verify_session_terminal.mjs exited #{other}:\n\n#{output}")
    end
  end
end
