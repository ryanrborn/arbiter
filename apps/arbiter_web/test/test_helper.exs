System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")

# bd-3ymdvi: `:node` tests drive the real terminal channel over a real
# WebSocket using `scripts/verify_session_transport.mjs` — the same client the
# coordinator runs for acceptance criterion 8 on the live host. No npm is
# involved (Node 22+ ships `WebSocket`, and `phoenix.mjs` is a Mix dependency),
# so they run by default and are skipped only where node is absent.
node_exclude = if System.find_executable("node"), do: [], else: [:node]

# bd-c76fu9: `:browser` tests bundle the real terminal hook with esbuild and
# run it inside a headless Chromium over the DevTools Protocol, because the
# canvas renderer and the §6.3 key bindings cannot be checked anywhere else.
# Still no npm — the browser and the esbuild binary are ones already on disk —
# but a machine without either has nothing to run, so the tag is excluded
# rather than failing.
chrome_candidates = [
  System.get_env("ARB_CHROME"),
  Path.expand("~/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome"),
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome"
]

browser_exclude =
  if node_exclude == [] and Enum.any?(chrome_candidates, &(&1 && File.exists?(&1))),
    do: [],
    else: [:browser]

ExUnit.start(exclude: node_exclude ++ browser_exclude)
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()
