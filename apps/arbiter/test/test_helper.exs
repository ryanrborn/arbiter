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

# bd-b95w36: `:systemd_user` is the restart-survival regression test — it
# starts a stand-in systemd user service, restarts it for real, and checks that
# a session launched from inside it survives with no gap in its output. Same
# opt-in reason as `:live_systemd`, plus one more: GitHub Actions runners often
# have no systemd user instance at all, so it *cannot* run there.
#
# That makes silence the risk. A suite that reports green while the one
# property every other phase assumes went unchecked is worse than no test, so
# the exclusion announces itself with its reason instead of hiding in ExUnit's
# "Excluding tags:" line.
systemd_user_reason =
  case Arbiter.Test.SystemdUser.status() do
    :ok -> nil
    {:unavailable, reason} -> reason
  end

ExUnit.start(exclude: [:live_systemd, :live_claude, :systemd_user] ++ tmux_exclude)

# `mix test` applies its `--include`/`--exclude` before loading this file, so
# the filters here are the run's real ones.
included = Keyword.get(ExUnit.configuration(), :include, [])

running_systemd_user? =
  Enum.any?(included, fn
    :systemd_user -> true
    {:systemd_user, _} -> true
    _ -> false
  end)

if not running_systemd_user? or systemd_user_reason != nil do
  IO.puts(Arbiter.Test.SystemdUser.banner(systemd_user_reason))
end

Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()

# Ensure Req's transitive apps are started for tests using Req.Test stubs.
{:ok, _} = Application.ensure_all_started(:req)
