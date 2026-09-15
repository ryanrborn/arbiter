defmodule ArbiterWeb.TerminalAssetsTest do
  @moduledoc """
  The asset-pipeline half of phase 5 (bd-c76fu9, acceptance criteria 1 and 6).

  `docs/browser-hosted-coordinator-sessions.md` §6.1 makes a promise that is
  very easy to break by accident and impossible to notice until a worktree
  somewhere fails to build: **this repo has no npm**. xterm arrives as vendored
  source, pinned by construction, with the upstream version written down next
  to it — not as a `package.json` entry that every one of the fleet's constantly
  recreated worktrees would then have to `npm install`.

  §6.2 is the other promise: the **canvas** renderer, never WebGL, because the
  dashboard is a multi-panel app the operator keeps open and a lost WebGL
  context renders as a blank terminal on the primary interface.

  Neither promise has a natural runtime failure that a test would otherwise
  catch, so they are asserted directly against the tree.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../../../assets", __DIR__)
  @vendor Path.join(@assets, "vendor/xterm")

  # {file, upstream package, pinned version}
  @bundles [
    {"xterm.js", "@xterm/xterm", "5.5.0"},
    {"addon-canvas.js", "@xterm/addon-canvas", "0.7.0"},
    {"addon-fit.js", "@xterm/addon-fit", "0.10.0"}
  ]

  describe "vendored xterm (§6.1)" do
    test "each bundle is on disk and names its upstream package and version" do
      for {file, package, version} <- @bundles do
        path = Path.join(@vendor, file)
        assert File.exists?(path), "missing vendored bundle #{path}"

        header = path |> File.read!() |> String.slice(0, 2_000)

        assert header =~ package,
               "#{file} must name its upstream package (#{package}) in a header comment"

        assert header =~ version,
               "#{file} must record the pinned upstream version (#{version}) in a header comment"
      end
    end

    test "xterm.css is vendored next to app.css and imported from it" do
      css = Path.join(@assets, "css/xterm.css")
      assert File.exists?(css), "xterm ships CSS; §6.1 requires it vendored into assets/css"
      assert File.read!(css) =~ "xterm"

      app_css = @assets |> Path.join("css/app.css") |> File.read!()
      assert app_css =~ ~s(@import "./xterm.css"), "app.css must import the vendored xterm.css"
    end

    test "no package.json and no node_modules were introduced" do
      refute File.exists?(Path.join(@assets, "package.json"))
      refute File.exists?(Path.join(@assets, "package-lock.json"))
      refute File.exists?(Path.join(@vendor, "package.json"))
      refute File.dir?(Path.join(@assets, "node_modules"))
    end

    test "the vendor directory records where the bundles came from" do
      readme = Path.join(@vendor, "README.md")
      assert File.exists?(readme), "an unattended blob of minified JS needs provenance"

      contents = File.read!(readme)
      assert contents =~ "registry.npmjs.org"

      for {_file, package, version} <- @bundles do
        assert contents =~ "#{package}@#{version}"
      end
    end
  end

  describe "canvas, not WebGL (§6.2)" do
    test "no WebGL addon is vendored or referenced anywhere in the asset tree" do
      offenders =
        @assets
        |> Path.join("**/*.{js,mjs,css,json}")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "addon-webgl"))

      assert offenders == [],
             "§6.2: the WebGL addon must not appear in the asset tree — #{inspect(offenders)}"

      refute File.exists?(Path.join(@vendor, "addon-webgl.js"))
    end

    test "the terminal hook loads the canvas addon" do
      hook = Path.join(@assets, "js/session_terminal.mjs")
      assert File.exists?(hook)

      source = File.read!(hook)
      assert source =~ "CanvasAddon"
      refute source =~ "WebglAddon"
    end
  end
end
