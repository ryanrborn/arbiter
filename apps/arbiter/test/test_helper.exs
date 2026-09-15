System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")

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
ExUnit.start(exclude: [:live_systemd, :live_claude])
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()

# Ensure Req's transitive apps are started for tests using Req.Test stubs.
{:ok, _} = Application.ensure_all_started(:req)
