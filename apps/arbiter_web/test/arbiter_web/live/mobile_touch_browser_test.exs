defmodule ArbiterWeb.MobileTouchBrowserTest do
  @moduledoc """
  bd-bcroux: the worker output pane's horizontal scroll and the session
  dock's close/maximize touch targets, at 375/414px in a real browser.

  `ArbiterWeb.WorkerDetailLiveTest` and `ArbiterWeb.SessionDockLiveTest` prove
  the markup carries the right classes (`overflow-x-auto`, `whitespace-pre`,
  `max-sm:size-11`, `max-sm:h-11`). Neither has a layout engine, so neither
  can show that a real browser actually turns those classes into a pane that
  scrolls sideways without dragging the page with it, or into a button that
  really measures 44px once Tailwind's `max-sm:` breakpoint and the dock's
  own strip-height media query both apply at a real phone width.

  So this boots the real endpoint on a real port and drives
  `scripts/verify_mobile_touch.mjs` against it at 375px and 414px, in both
  themes, plus a 1280px desktop regression pass. The bundle is rebuilt
  in-process with `Esbuild.run/2` and `Tailwind.run/2` — never by shelling out
  to `mix`, which would deadlock on the build lock the surrounding `mix test`
  holds. Skipped, not failed, where there is no Chromium (the script exits
  `3`) or no esbuild/tailwind binary.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded worker/session, and the listener binds a
  # real port.
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Worker

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_mobile_touch.mjs"

  @listener_id :mobile_touch_listener

  setup %{tmp_dir: tmp_dir} do
    Arbiter.Test.SessionEnv.sandbox("mobile-touch")
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_runner, NoopRunner)

    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    :ok
  end

  test "the output pane scrolls horizontally and the dock's close/maximize are touch-sized" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    {:ok, ws} =
      Ash.create(Workspace, %{name: "mt-ws-#{System.unique_integer([:positive])}", prefix: "mt"})

    {:ok, task} = Ash.create(Issue, %{title: "mt-mobile-touch", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo")

    # A single unbroken run long enough to guarantee horizontal overflow at
    # 375px regardless of font metrics.
    long_line = "worker output " <> String.duplicate("0123456789-", 40)
    :ok = Worker.report(pid, :output_lines, [long_line])

    {:ok, _session} = Sessions.launch(name: "mobile touch session", runner: NoopRunner)

    case build_assets() do
      :ok -> drive(node, task.id)
      {:skipped, why} -> IO.puts("\n[skipped] " <> why)
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

  defp drive(node, task_id) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        [@script, "--url", "http://localhost:#{port}", "--task", task_id, "--seconds", "30"] ++
          screenshot_args(),
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_mobile_touch.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_mobile_touch.mjs failed:\n\n#{output}")
    end
  end

  # `ARB_MOBILE_TOUCH_SCREENSHOT=/path/to.png mix test ...` leaves a set of
  # before/after PNGs behind, one per width/theme combo plus desktop. Nothing
  # asserts on them; they are for the PR description.
  defp screenshot_args do
    case System.get_env("ARB_MOBILE_TOUCH_SCREENSHOT") do
      nil -> []
      path -> ["--screenshot", path]
    end
  end

  # `port: 0` lets the kernel pick and we read the bound port back off
  # Thousand Island, so a sibling VM on this host can never lose a race for a
  # port we probed for and had not yet bound.
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
