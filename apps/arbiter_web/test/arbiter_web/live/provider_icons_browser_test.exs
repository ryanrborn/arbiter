defmodule ArbiterWeb.ProviderIconsBrowserTest do
  @moduledoc """
  The Claude, Codex and Antigravity marks on the workers index, in a real
  browser (bd-aro53b).

  `ArbiterWeb.CoreComponents.ProviderIconTest` and `WorkerIndexLiveTest` prove
  the markup — an `<svg>`, a `<title>`, an `aria-label`, filter/mask ids. They
  cannot prove that all three marks actually paint vector content and render
  at a legible, distinct size on a real Running-card-style list in both
  themes; `ConnCase` has no layout engine.

  So this boots the real endpoint on a real port, starts one worker per
  provider, and drives `scripts/verify_provider_icons.mjs` against it.
  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary. Set `ARB_PROVIDER_ICON_SHOTS=<dir>` to also get PNGs
  of the workers index in both themes.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded workers, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_provider_icons.mjs"

  @listener_id :provider_icons_listener

  test "claude, codex and antigravity marks render, load, and are legible in both themes" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-icons-#{System.unique_integer([:positive])}"})

    for provider <- ["claude", "codex", "gemini"] do
      {:ok, task} = Ash.create(Issue, %{title: "worker-#{provider}", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.report(pid, :provider, provider)
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

    shots =
      case System.get_env("ARB_PROVIDER_ICON_SHOTS") do
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
      IO.puts("\n--- verify_provider_icons.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_provider_icons.mjs failed:\n\n#{output}")
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
