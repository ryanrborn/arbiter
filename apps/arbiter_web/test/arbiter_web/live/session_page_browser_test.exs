defmodule ArbiterWeb.SessionPageBrowserTest do
  @moduledoc """
  `/sessions` in a real browser, from the launch click onwards (bd-3r2otb,
  acceptance criteria 1-4).

  Every bug this test exists for was invisible to the rest of the suite.
  `ArbiterWeb.SessionIndexLiveTest` renders the page's chrome without a hook,
  `ArbiterWeb.SessionTerminalBrowserTest` drives the terminal on a bare
  `file://` page without LiveView, and `ArbiterWeb.SessionTransportSocketTest`
  drives the channel without a browser. The first live check of phase 5 broke
  in exactly the seam none of them cover: the operator clicked "Launch", the
  page live-navigated to `/sessions/<id>`, and the terminal's `/session`
  socket was never opened at all — the server logged no connect until a manual
  refresh.

  So this boots the real endpoint on a real port and drives a real Chromium
  through the real thing: click launch, wait for the status strip to say
  `live`, measure that the fitted pane ends inside its container at three
  window sizes, press a **trusted** `Ctrl+Shift+C`/`+V`, and kill the session
  from the window's own overflow while the page is open.

  Since bd-9myzv8 the terminal lives in the session dock, so that is the pane
  these four criteria are measured against; since bd-a292yj there is no
  `/sessions/<id>` to navigate to at all — Launch opens the window in the dock,
  on the page the operator is already on, and criterion 4 asserts phase 3's
  shape of a kill: the pane stays, read-only, with its scrollback and end
  reason, until it is dismissed. What the dock adds on top — resume across a
  collapse, survival across navigation — is
  `ArbiterWeb.SessionDockTerminalBrowserTest`.

  The page is served from the real bundle, so the bundle has to be current: a
  stale `priv/static/assets` would test the JS of whatever commit last built
  it, which is the failure mode of the bug itself. It is rebuilt here by
  calling `Esbuild.run/2` and `Tailwind.run/2` directly — never by shelling out
  to `mix`, which would deadlock on the build lock the surrounding `mix test`
  already holds.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the session rows, and the listener binds a real port.
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Test.ScriptedPty

  @moduletag :browser
  @moduletag :tmp_dir
  # A browser launch plus a session launch plus three fits.
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_session_page.mjs"

  @listener_id :session_page_listener

  setup %{tmp_dir: tmp_dir} do
    Arbiter.Test.SessionEnv.sandbox("session-page")
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_terminal, ScriptedPty)
    put_env(:sessions_runner, NoopRunner)
    put_env(Arbiter.Sessions.Stream, poll_interval_ms: 5, alive_interval_ms: 50)

    :ok
  end

  test "launching from the dashboard reaches a live, fitted, killable terminal" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok -> drive(node)
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # The same two commands `mix assets.build` runs, called in-process: the CSS
  # carries the pane's `h-[min(70vh,640px)] p-2`, which is the box the fit is
  # measured against, and the JS carries the hook.
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

  defp drive(node) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the socket's Origin
        # against the endpoint's configured host, and a browser sends the one
        # it was pointed at.
        [@script, "--url", "http://localhost:#{port}", "--seconds", "30"],
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_session_page.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"
        assert_paste_reached_the_pane(output)

      _other ->
        flunk("verify_session_page.mjs failed:\n\n#{output}")
    end
  end

  # The browser can only prove the key reached the hook. Whether the pane
  # actually received the clipboard is a server-side fact, and the scripted PTY
  # records every byte typed into it.
  defp assert_paste_reached_the_pane(output) do
    [_, session_id] = Regex.run(~r/^SESSION (\S+)$/m, output)

    assert ScriptedPty.input(session_id) =~ "pasted-through-the-browser",
           "Ctrl+Shift+V never reached the pane: #{inspect(ScriptedPty.input(session_id))}"

    assert {:ok, %{status: :ended}} = Sessions.get(session_id)
  end

  # -- listener ---------------------------------------------------------------

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
