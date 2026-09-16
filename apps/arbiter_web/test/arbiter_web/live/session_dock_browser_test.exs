defmodule ArbiterWeb.SessionDockBrowserTest do
  @moduledoc """
  The session dock in a real browser (bd-dlc136).

  This exists for the one acceptance criterion `ArbiterWeb.SessionDockLiveTest`
  structurally cannot reach: *LiveView navigation does not re-mount the dock.*
  Survival is a client-side fact about `data-phx-sticky` — on a `live_redirect`
  the client moves the existing dock element into the incoming main container
  instead of re-rendering it. `Phoenix.LiveViewTest` has no client, so under
  `ConnCase` every navigation is a fresh `live/2` and the dock is a fresh
  process whether or not `sticky: true` is there at all. A suite that only
  asserted the attribute would still pass the day the mechanism stopped
  working.

  So this boots the real endpoint on a real port and drives real Chromium:
  stamp the dock's DOM node with a JS property no server render can recreate,
  open a session into the strip, live-navigate, and check the stamp, the
  window, its expansion and the roster's scroll offset all came through.
  Then reload outright and check the dock rebuilds itself from `localStorage`.

  The page is served from the real bundle, so the bundle has to be current: it
  is rebuilt here by calling `Esbuild.run/2` and `Tailwind.run/2` directly —
  never by shelling out to `mix`, which would deadlock on the build lock the
  surrounding `mix test` already holds. The Tailwind build is load-bearing for
  one of the checks: `pb-[var(--session-dock-strip-height)]` is an arbitrary
  value that only reserves room for the strip if it actually compiled.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the session rows, and the listener binds a real port.
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_session_dock.mjs"

  @listener_id :session_dock_listener

  # Enough rows that the roster panel overflows its max height: the scroll
  # offset is one of the things navigation has to preserve, and a panel that
  # cannot scroll would make that check vacuous.
  @session_count 14

  setup %{tmp_dir: tmp_dir} do
    Arbiter.Test.SessionEnv.sandbox("session-dock-browser")
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  test "the dock survives live navigation and a reload" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    for n <- 1..@session_count do
      {:ok, _session} = Sessions.launch(name: "dock session #{n}", runner: NoopRunner)
    end

    case build_assets() do
      :ok -> drive(node)
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # The same two commands `mix assets.build` runs, called in-process.
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
      IO.puts("\n--- verify_session_dock.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"
        assert_the_session_was_left_alone(output)

      _other ->
        flunk("verify_session_dock.mjs failed:\n\n#{output}")
    end
  end

  # The dock opened and then dismissed a session. Dismiss is a view action —
  # if it ever grew a kill or a detach, this is where it would show.
  defp assert_the_session_was_left_alone(output) do
    [_, session_id] = Regex.run(~r/^SESSION (\S+)$/m, output)

    assert {:ok, %{status: :running, ended_at: nil}} = Sessions.get(session_id)
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
