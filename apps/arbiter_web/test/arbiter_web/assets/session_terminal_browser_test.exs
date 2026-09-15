defmodule ArbiterWeb.SessionTerminalBrowserTest do
  @moduledoc """
  The claims that only a real browser can settle (bd-c76fu9, phase 5
  acceptance criteria 2, 5 and 6).

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
        refute output =~ ": FAIL"

      other ->
        flunk("verify_session_terminal.mjs exited #{other}:\n\n#{output}")
    end
  end
end
