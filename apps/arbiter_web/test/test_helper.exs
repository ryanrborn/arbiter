System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")

# bd-3ymdvi: `:node` tests drive the real terminal channel over a real
# WebSocket using `scripts/verify_session_transport.mjs` — the same client the
# coordinator runs for acceptance criterion 8 on the live host. No npm is
# involved (Node 22+ ships `WebSocket`, and `phoenix.mjs` is a Mix dependency),
# so they run by default and are skipped only where node is absent.
node_exclude = if System.find_executable("node"), do: [], else: [:node]

ExUnit.start(exclude: node_exclude)
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()
