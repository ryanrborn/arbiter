defmodule ArbiterWeb.NavRailBrowserTest do
  @moduledoc """
  The nav rail in a real browser at real viewports (bd-d63b1c).

  `ArbiterWeb.LayoutsTest` proves the rail's markup and the stylesheet's inset
  rules; `ArbiterWeb.NavRailLiveTest` proves the active item. None of that can
  show where a layout engine actually puts the page: that hovering the rail
  floats it without moving the content, that pinning moves the content by
  exactly the rail's growth, that the pin is applied before first paint on a
  reload, and that the below-`lg` overlay opens, dismisses and closes on
  navigation. `ConnCase` has no layout engine.

  So this boots the real endpoint on a real port and drives
  `scripts/verify_nav_rail.mjs` against it at 1280px and 800px. The bundle is
  rebuilt in-process with `Esbuild.run/2` and `Tailwind.run/2` — never by
  shelling out to `mix`, which would deadlock on the build lock the
  surrounding `mix test` holds. Skipped, not failed, where there is no
  Chromium (the script exits `3`) or no esbuild/tailwind binary.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded run, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Workers.Run

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_nav_rail.mjs"

  @listener_id :nav_rail_listener

  test "the rail floats on hover, insets when pinned, persists, and overlays below lg" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok -> drive(node, seed_run())
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  defp seed_run do
    {:ok, run} =
      Ash.create(Run, %{
        repo: "arbiter",
        workspace_id: "ws-1",
        task_id: "bd-rail",
        task_title: "rail-run",
        status: :completed,
        worker_type: "main",
        started_at: DateTime.add(DateTime.utc_now(), -120, :second),
        completed_at: DateTime.utc_now()
      })

    run.id
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

  defp drive(node, run_id) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host.
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--run",
          to_string(run_id),
          "--seconds",
          "30"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_nav_rail.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_nav_rail.mjs failed:\n\n#{output}")
    end
  end

  # `port: 0` lets the kernel pick; the bound port is read back off Thousand
  # Island so a sibling VM can never lose a race for it.
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
