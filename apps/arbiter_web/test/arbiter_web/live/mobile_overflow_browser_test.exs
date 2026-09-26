defmodule ArbiterWeb.MobileOverflowBrowserTest do
  @moduledoc """
  Usage, Issue detail and Audit at phone width (bd-39kw9e).

  `UsageLiveTest`, `TaskDetailLiveTest` and `AuditLogLiveTest` prove each
  page's *data*. None of them can prove "fits at 375/414px with nothing
  overflowing" — `ConnCase` has no layout engine, so a claim like `flex-wrap`
  being present on a div is a claim about an attribute, not about whether the
  browser actually wraps the row instead of pushing it off-screen. This boots
  the real endpoint on a real port and measures the rendered boxes with
  headless Chromium, in both themes, at 375px, 414px and (as a desktop
  regression check) 1280px.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_mobile_overflow.mjs"

  @listener_id :mobile_overflow_listener

  test "Usage, Issue detail and Audit pages have no horizontal overflow at phone width" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok -> drive(node, seed())
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # An open, unrefined, unassigned issue renders every operator action button
  # (Refine-eligible or not, Move to Ready, Edit, Dispatch, Close) — the
  # widest form of the action row. A status transition (open -> ready) gives
  # the audit log a real "old -> new" Detail cell to measure.
  defp seed do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "mob-#{n}", prefix: "mob#{n}"})

    {:ok, task} =
      Ash.create(Issue, %{
        title: "Browser-verified issue for mobile overflow checks",
        workspace_id: ws.id,
        acceptance: "The page fits at 375px and 414px with no horizontal overflow."
      })

    {:ok, task} = Ash.update(task, %{}, action: :promote_to_ready)

    %{task_id: task.id}
  end

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

  defp drive(node, %{task_id: task_id}) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--task",
          task_id,
          "--seconds",
          "30"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_mobile_overflow.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_mobile_overflow.mjs failed:\n\n#{output}")
    end
  end

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
