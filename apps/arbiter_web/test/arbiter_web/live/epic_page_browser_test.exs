defmodule ArbiterWeb.EpicPageBrowserTest do
  @moduledoc """
  The `/epics` page in a real browser at a real narrow width (bd-2wmxt5,
  acceptance criterion 6).

  `ArbiterWeb.EpicIndexLiveTest` proves the page's *data* — the right epics,
  the right buckets, the right chips, live on PubSub. What it cannot prove is
  "usable at ~400px width, with rows stacked": `ConnCase` has no layout engine,
  so the closest it can get is asserting that a row carries `flex-col
  sm:flex-row`, which is a claim about an attribute rather than about where the
  browser actually puts the two halves of the row. A stray `min-w-[...]`, a
  title that forgets to truncate, or a progress bar with no flexible width all
  leave those classes exactly where they are and still push the row past the
  viewport.

  So this boots the real endpoint on a real port, seeds an epic with children
  in every bucket and a blocked one for good measure, and measures the rendered
  row at 1280px and at 400px: side-by-side above the breakpoint, stacked below
  it, nothing overflowing, and every piece of it still drawn.

  The page is served from the real bundle, so the bundle has to be current —
  rebuilt here by calling `Esbuild.run/2` and `Tailwind.run/2` directly, never
  by shelling out to `mix`, which would deadlock on the build lock the
  surrounding `mix test` already holds. The CSS is not optional: the stacking
  under test *is* a Tailwind class.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded rows, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_epics_page.mjs"

  @listener_id :epic_page_listener

  test "the epic row stacks and stays inside the viewport at 400px" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok -> drive(node, seed())
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # One epic carrying a child in every bucket plus an open gating blocker, so
  # the row renders its widest form: long title, progress bar, five-segment
  # breakdown and all three stuck chips at once. A row that fits at 400px in
  # that state fits in any state.
  defp seed do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "epb-#{n}", prefix: "epb#{n}"})

    {:ok, epic} =
      Ash.create(Issue, %{
        title: "Browser-verified epic with a deliberately long title that has to truncate",
        workspace_id: ws.id,
        issue_type: :epic,
        auto_close: true
      })

    for {title, as} <- [
          {"backlog child", :backlog},
          {"ready child", :ready},
          {"running child", :running},
          {"waiting child", :waiting},
          {"closed child", :closed}
        ] do
      child(ws, epic, title, as)
    end

    blocked = child(ws, epic, "blocked child", :ready)
    {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ws.id})
    {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

    %{epic_id: epic.id, badge: Tasks.open_epic_count()}
  end

  defp child(ws, epic, title, as) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, issue_type: :task})

    issue =
      case as do
        :backlog -> issue
        :ready -> Ash.update!(issue, %{}, action: :promote_to_ready)
        :running -> Ash.update!(issue, %{status: :in_progress})
        :waiting -> Ash.update!(issue, %{}, action: :await_verification)
        :closed -> Ash.update!(issue, %{}, action: :close)
      end

    {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)
    issue
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

  defp drive(node, %{epic_id: epic_id, badge: badge}) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host, and a browser sends
        # the one it was pointed at.
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--epic",
          epic_id,
          "--badge",
          Integer.to_string(badge),
          "--seconds",
          "30"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_epics_page.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_epics_page.mjs failed:\n\n#{output}")
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
