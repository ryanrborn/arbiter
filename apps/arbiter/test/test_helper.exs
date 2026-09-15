System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
# bd-aprlbb: same reason as the two above — `Arbiter.Config.Paths.resolve/3` is
# env-first, so an exported ARBITER_SESSIONS_ROOT would beat both `config/test.exs`
# and `Arbiter.Test.SessionEnv`'s `put_env`, and the suite would provision real
# session scaffolds into the operator's configured root (which SessionEnv's
# `on_exit`, cleaning only its own tmp dir, would then never remove).
System.delete_env("ARBITER_SESSIONS_ROOT")

# bd-bpt0ag: `:live_systemd` tests spawn REAL systemd user scopes and tmux
# servers on whatever host runs them, so they are opt-in rather than part of
# `mix precommit`. Run them deliberately:
#
#     mix test --include live_systemd
#
# Every one of them tears down by exact unit name and exact socket path — this
# repo has an incident class around pattern-based kills reaching the live
# coordinator.
# bd-aprlbb: `:live_claude` tests start the REAL `claude` CLI interactively and
# assert it reaches a prompt with no onboarding wizard (RFC §9.2). Opt-in for
# the same reason, plus a credential one — see the test's moduledoc:
#
#     mix test --include live_claude test/integration/session_onboarding_test.exs
# bd-3ymdvi: `:tmux` tests run a real tmux server on a scratch socket in the
# test's own `tmp_dir` — no systemd, no session row, torn down by exact socket
# path. They are cheap and they are the only proof that phase 4's tmux argv is
# right on the tmux that is installed, so they run by default and are skipped
# only where tmux is absent.
tmux_exclude = if System.find_executable("tmux"), do: [], else: [:tmux]

ExUnit.start(exclude: [:live_systemd, :live_claude] ++ tmux_exclude)
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()

# Ensure Req's transitive apps are started for tests using Req.Test stubs.
{:ok, _} = Application.ensure_all_started(:req)
