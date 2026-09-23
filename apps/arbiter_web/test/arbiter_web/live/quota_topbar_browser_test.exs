defmodule ArbiterWeb.QuotaTopbarBrowserTest do
  @moduledoc """
  The status bar's quota rows in a real browser at real viewports (bd-gukyy1).

  `ArbiterWeb.QuotaTopbarTest` proves the markup — a row per provider, two bars
  each, the chrome still rendered. It cannot show that a second stacked row
  actually fits inside the 46px status bar, or that the live badge, inbox
  trigger and theme toggle still fit beside the bars at `lg` without overlap
  or overflow, or that the provider hues resolve distinctly in both themes.
  `ConnCase` has no layout engine.

  So this boots the real endpoint on a real port, seeds a Claude and an
  Antigravity quota on the default workspace, and drives
  `scripts/verify_quota_topbar.mjs` against it. Skipped, not failed, where
  there is no Chromium (the script exits `3`) or no esbuild/tailwind binary.
  Set `ARB_QUOTA_SHOTS=<dir>` to also get PNGs of the status bar.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded quotas, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.QuotaFixtures

  alias Arbiter.Tasks.Workspace

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_quota_topbar.mjs"

  @listener_id :quota_topbar_listener

  test "claude and antigravity rows stack inside the status bar and the chrome still fits" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    ws = Ash.create!(Workspace, %{name: "default"})

    {:ok, _} =
      Arbiter.Quota.capture(ws.id, [
        {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
        {"anthropic-ratelimit-unified-7d-utilization", "0.18"}
      ])

    antigravity_quota!(ws)

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

    shots =
      case System.get_env("ARB_QUOTA_SHOTS") do
        nil -> []
        dir -> ["--shots", dir]
      end

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host.
        [@script, "--url", "http://localhost:#{port}", "--seconds", "30"] ++ shots,
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_quota_topbar.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_quota_topbar.mjs failed:\n\n#{output}")
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
