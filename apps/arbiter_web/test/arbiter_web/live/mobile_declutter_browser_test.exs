defmodule ArbiterWeb.MobileDeclutterBrowserTest do
  @moduledoc """
  The Sessions list and Workspace detail pages at phone widths, in a real
  browser (bd-9inpfa).

  `ArbiterWeb.CoreComponents.DomainTest`, `ArbiterWeb.SessionIndexLiveTest`
  and `ArbiterWeb.WorkspaceConfigScreenTest` pin the responsive Tailwind
  classes these two pages now carry. None of them has a layout engine, so
  none can prove the acceptance criterion those classes exist for: no
  page-level horizontal scroll at 375px or 414px, in light or dark, and no
  regression at 1280px. So this boots the real endpoint on a real port and
  drives `scripts/verify_mobile_declutter.mjs` against it — reading back
  `document.documentElement.scrollWidth` the way an operator's phone would
  render it, not the markup a template emitted.

  `--shots` also asks the script for a PNG per page/viewport/theme, written
  to a private `tmp_dir` (ExUnit's `@moduletag :tmp_dir`, cleaned up with the
  test) — the same real captures pinned into the PR body are pulled from a
  run of this test with `ARB_MOBILE_SHOTS` set to a durable directory.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or
  no esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded workspace/session, and the listener binds a
  # real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.NoopRunner

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_mobile_declutter.mjs"

  @listener_id :mobile_declutter_listener

  setup do
    Arbiter.Test.SessionEnv.sandbox("mobile-declutter-browser")
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  test "no horizontal scroll on /sessions and /workspaces/:id at 375/414px, light and dark", %{
    tmp_dir: tmp_dir
  } do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok ->
        seed_session()
        drive(node, seed_workspace(), tmp_dir)

      {:skipped, why} ->
        IO.puts("\n[skipped] #{why}")
    end
  end

  # Seeded so /sessions renders a real row (`#sessions-list`) rather than the
  # empty state — the row is what the ticket's crowding was actually about.
  defp seed_session do
    {:ok, session} = Sessions.launch(runner: NoopRunner)
    session
  end

  defp seed_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "wx",
        config: %{"tracker" => %{"type" => "github"}}
      })

    ws.id
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  # The same two commands `mix assets.build` runs, called in-process — never
  # `mix` itself, which would deadlock on the build lock this `mix test` run
  # already holds.
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

  defp drive(node, workspace_id, tmp_dir) do
    port = start_listener!()
    shots = System.get_env("ARB_MOBILE_SHOTS") || tmp_dir

    {output, status} =
      System.cmd(
        node,
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--workspace-id",
          workspace_id,
          "--shots",
          shots,
          "--seconds",
          "30"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_mobile_declutter.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_mobile_declutter.mjs failed:\n\n#{output}")
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
