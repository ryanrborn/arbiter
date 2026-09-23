import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

Code.require_file("support/test_db_partition.ex", __DIR__)

# bd-2xvwew: `MIX_TEST_PARTITION` is only set when the caller explicitly
# shards a single run via `mix test --partitions N` (each shard already wants
# its own file, by design). It is NOT set for the common case of several
# `mix test` invocations running concurrently from different worktrees on the
# same host, so fall back to a cwd-derived suffix — every worktree gets an
# isolated database file with no coordination required from the caller. See
# Arbiter.TestDbPartition for why this matters (it's not just about avoiding
# slow queueing — concurrent invocations sharing a file corrupt each other's
# schema).
test_db_partition =
  System.get_env("MIX_TEST_PARTITION") || Arbiter.TestDbPartition.suffix()

config :arbiter, Arbiter.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "arbiter_test_#{test_db_partition}.sqlite3"
    ),
  journal_mode: :wal,
  # SQLite allows only one writer at a time, and a *second* class of failure
  # is invisible to `busy_timeout`: under WAL, a connection that began its
  # read snapshot before another connection committed a write cannot silently
  # upgrade to a writer against that stale snapshot — SQLite returns
  # SQLITE_BUSY_SNAPSHOT immediately, without ever invoking the busy handler
  # `busy_timeout` installs (this is documented SQLite WAL behavior, not an
  # Exqlite bug). Ecto.Adapters.SQL.Sandbox holds each test's transaction open
  # for that test's whole lifetime, so with `pool_size: schedulers_online() *
  # 2` (many) concurrent sandboxed connections all taking snapshots and
  # writing against the same on-disk file, that race was common enough to
  # show up as flaky `(Exqlite.Error) Database busy` failures scattered across
  # unrelated test modules (bd-9j4znl) — not a bug in any of those tests.
  # `busy_timeout` still buys headroom for the *ordinary* one-writer-at-a-time
  # queueing case, so it stays generous; `pool_size: 1` closes the
  # snapshot race by ensuring there is only ever one live sandboxed
  # connection, so concurrent `async: true` tests queue for that single
  # connection (via DBConnection's own queue, not SQLite's busy handler)
  # instead of racing each other's WAL snapshots.
  busy_timeout: 60_000,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1,
  # bd-2xvwew: with `pool_size: 1`, the whole async suite serializes through
  # one connection — fine under light load, but DBConnection's queue sheds
  # load *before* the nominal checkout timeout once the queue's average wait
  # exceeds `:queue_target` within `:queue_interval` (defaults: 50ms/1000ms).
  # Several `mix test` invocations genuinely competing for CPU (e.g. one per
  # concurrently-dispatched worker, each in its own worktree) legitimately
  # pushes the single connection's queue past that default in bursts, and
  # DBConnection was failing checkouts after 2-4s with `:queue_timeout` on
  # tests that never touched the code under test (the exact failure mode this
  # config predicted when pool_size was first dropped to 1 — see bd-9j4znl).
  # Raising these gives the queue room to drain a legitimate burst instead of
  # rejecting it; it does NOT add a second live connection, so it can't
  # reintroduce the SQLITE_BUSY_SNAPSHOT race pool_size: 1 exists to prevent.
  queue_target: 5_000,
  queue_interval: 15_000

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tP+Fx7+LODDAMtW348NLPMEFQgFBNOCXEW1X3LdQHm5YMSdusJH7vaCC+c18IJgi",
  server: false

# Cloak vault key for the test suite. Arbiter.Vault reads ARBITER_CLOAK_KEY at
# runtime and refuses to boot without it; this config fallback injects a fixed
# (non-secret) 32-byte AES key so the suite encrypts/decrypts workspace secrets
# without depending on a real environment variable. Never used outside :test.
config :arbiter, Arbiter.Vault, key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

config :arbiter, :github_http_stub, true
# The GitHub limiter's owning-account resolution and periodic /rate_limit poll
# both make real HTTP calls; disable that probing in the suite so the app-wide
# singleton never reaches out. Its priority/headroom/secondary logic is still
# fully exercised (LimiterTest starts isolated instances; the integration tests
# drive it via Req.Test stubs).
config :arbiter, :github_limiter_probe, false

# bd-a9zb7w: a ReviewGate REQUEST_CHANGES verdict now auto-dispatches an
# implementer fix round (`Arbiter.Worker.maybe_dispatch_fix_round/3`). The real
# dispatcher calls `Dispatch.resume/2` — a worktree, a fresh worker, a live
# agent — which no test that merely drives a rejection verdict wants. Point the
# suite at the recording stub instead: tests that care assert against
# `Arbiter.Test.StubFixRoundDispatcher`, and every other one gets a no-op.
config :arbiter,
       :review_gate_fix_round_dispatcher,
       Arbiter.Test.StubFixRoundDispatcher

# bd-8y1i58: the app-wide limiter singleton outlives every individual test, and
# a secondary-limit trip parks background traffic for a *wall-clock* cooldown.
# One test stubbing a 403-with-headroom therefore poisoned every later test that
# polls under `:background` — MergeQueue, PRPatrol, PrStatePoller, ReviewPatrol,
# MergedPRFinalizer — with an order-dependent "background request paused
# (secondary_backoff)". A zero cooldown keeps the trip observable (the
# `secondary_trips` counter still increments) without leaking a pause across
# test boundaries; the tests that actually exercise the cooldown start their own
# limiter with an explicit `secondary_cooldown_ms`.
config :arbiter, :github_limiter_secondary_cooldown_ms, 0
config :arbiter, :jira_http_stub, true
config :arbiter, :shortcut_http_stub, true
config :arbiter, :gitlab_http_stub, true
config :arbiter, :oauth_usage_http_stub, true
config :arbiter, :auto_start_refineries, false

# Worker CLAUDE_CONFIG_DIR isolation (bd-3y2mda) is off by default in the suite
# so unit tests never touch the real cache dir or symlink the operator's config.
# Tests that exercise isolation enable it and point :worker_config_dir at a tmp
# dir of their own.
config :arbiter, :worker_isolate_config, false

# Provider accounts (P3, bd-aiodva): the read flip is a *matrix*, not a single
# run — acceptance 5 is "the suite passes with the flag both on and off". The
# default `mix test` run keeps the production default (off, the pre-P3 read
# paths); `ARBITER_PROVIDER_ACCOUNTS=1 mix test` runs the same suite with the
# accounts tables as the credential source. Tests that pin one side explicitly
# (Application.put_env in their own setup) are unaffected by either leg.
config :arbiter, :provider_accounts_enabled, System.get_env("ARBITER_PROVIDER_ACCOUNTS") == "1"

# Arbiter.MCP (bd-dem49g): the server stays enabled (Plug tests exercise it), but
# per-spawn `.mcp.json` injection into worktrees is off by default so existing
# Sling tests don't write config files or mint tokens. Tests that exercise
# injection flip `inject_config: true` themselves.
#
# `sse_max_lifetime_ms: 0` closes a GET /mcp SSE stream right after the initial
# keepalive flush, so the synchronous test request returns instead of blocking
# on the held-open stream (bd-3m4yop).
config :arbiter, Arbiter.MCP, inject_config: false, sse_max_lifetime_ms: 0

# Durable per-run transcript root, isolated under tmp so the suite never
# writes into a real data dir. Tests that assert on transcripts override this
# per-test with a unique tmp dir.
config :arbiter, :output_log_root, Path.join(System.tmp_dir!(), "arbiter-worker-logs-test")

# `Arbiter.Worker.Worktree` and `Arbiter.Reviews.Checkout` both resolve their
# root via `Arbiter.Config.Paths.worktree_root/0`, whose ultimate fallback is
# a `$HOME`-relative default that isn't writable/isolated for the test suite.
# Historically (before that resolver existed) this config key being unset
# meant a hardcoded fallback path from the original author's machine, and any
# test exercising either module (`CheckoutTest`, `ExternalReviewTest`,
# `MergeQueueConflictTest`, ...) failed with `:eacces` — UNLESS it happened to
# run concurrently with `WorktreeTest`, whose setup/on_exit temporarily points
# `:worktree_root` at its own tmp dir for the duration of its own tests. That
# incidental overlap is what made the failures look order-dependent (bd-9j4znl).
# Tests that need their own isolated root still override this per-test.
#
# bd-b6noq9 (#1930): NOT under `System.tmp_dir!()`. A worktree holds real git
# data for the lifetime of the run using it, and on the dogfood host `/tmp` is
# a tmpfs swept daily by `systemd-tmpfiles` — a root nothing in Arbiter
# controls. `scratch_root/0` is disk-backed and under `$HOME/.cache`.
# Mirrors `Arbiter.Config.Paths.scratch_root/0`, which cannot be called from a
# config script (the app isn't loaded yet) — hence the inline resolution. The
# key is also configured so the resolver and this file agree even where the
# two defaults could diverge (HOME unset).
scratch_root =
  System.get_env("ARBITER_SCRATCH_ROOT") ||
    Path.join(System.get_env("HOME") || System.tmp_dir!(), ".cache/arbiter/scratch")

config :arbiter, :scratch_root, scratch_root
config :arbiter, :worktree_root, Path.join(scratch_root, "worktrees-test")

# Stalled-worker detection (bd-awi4nw): shorten the post-exit grace so the
# deferred classify+escalate check fires fast under test. Still > 0 so a normal
# completion's in-flight `arb done` wins the race before the check runs.
config :arbiter, :worker_exit_grace_ms, 50
config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true

# Disable the pr_state background poller in test — it would otherwise hit the
# forge on a timer. Tests drive `Arbiter.Reviews.PrStatePoller.poll/1`
# synchronously with a Req.Test stub and start their own disabled instance.
config :arbiter, :pr_state_poller, enabled: false

# Disable the stale-review reaper in test — it would otherwise sweep every
# :running ExternalReview record a test creates on a timer, off the sandbox
# connection. Tests drive `Arbiter.Reviews.StaleReviewReaper.reap/1`
# synchronously with an explicit :timeout_ms.
config :arbiter, :stale_review_reaper, enabled: false

# bd-a370ak: tests drive PendingMergeSweeper.sweep/1 synchronously.
config :arbiter, :pending_merge_sweeper, enabled: false

# Disable the coordinator-session reaping GenServers in test — they would
# otherwise sweep/touch on a timer, off the sandbox connection. Tests drive
# `Arbiter.Sessions.IdleReaper.reap/1`, `Arbiter.Sessions.OrphanReaper.sweep_once/2`
# and `Arbiter.Sessions.Heartbeat.touch/0` synchronously (bd-3qkbch, phase 10).
config :arbiter, :sessions_idle_reaper, enabled: false
config :arbiter, :sessions_orphan_reaper, enabled: false
config :arbiter, :sessions_heartbeat, enabled: false

# Same reasoning, one more sweeper: tests drive
# `Arbiter.Sessions.TranscriptRetention.sweep/1` synchronously (§11, phase 9).
config :arbiter, :sessions_transcript_retention, enabled: false

# A small cap here keeps `TranscriptTest`'s size-cap test from materialising
# a 100 MB default three times over (bd-5pelo2 round 4 finding 4).
config :arbiter, :sessions_transcript, max_bytes: 1024

# §8.3's bridge-verification poll (`Arbiter.Sessions.verify_bridge/2`, phase
# 8) defaults to a 15s timeout, backgrounded on every `launch/1` call with
# `remote_control: true` — a real 15s poll under the default settings would
# otherwise run, unwatched, behind every such test that does not override it
# itself. Small enough here that a test asserting the "bridge never came up"
# path (the common case: nothing in a test's throwaway config dir ever writes
# a `bridge-session` record) settles in milliseconds instead.
config :arbiter, :sessions_bridge_verify_timeout_ms, 50
config :arbiter, :sessions_bridge_verify_poll_interval_ms, 10

# Disable the Stage 3 canary ticker in test — it would otherwise walk every
# workspace a test creates on a timer, off the sandbox connection. Tests drive
# `Arbiter.Loop.CanaryTicker.poll/1` synchronously on their own instance.
config :arbiter, :loop_canary_ticker, enabled: false

# bd-8j9i9p: no background over-budget sweep in test — it would otherwise walk
# every issue a test creates on a timer, off the sandbox connection. Tests
# drive `Arbiter.Usage.BudgetPatrol.sweep/1` synchronously.
config :arbiter, :budget_patrol, enabled: false

# Disable the durable events retention sweeper in test — it would otherwise
# delete rows on a timer off the sandbox connection. Tests drive
# `Arbiter.Events.Retention.sweep/1` synchronously.
config :arbiter, :events_retention, enabled: false

# bd-be804c: no background sweep of anyone's ~/.claude in the suite — the tests
# drive `Arbiter.Sessions.UsageIngest.ingest/1` synchronously against fixtures.
config :arbiter, :coordinator_session_ingest, enabled: false
config :arbiter, :coordinator_session_dirs, []

# Disable the Codex / Gemini CLI / Antigravity refresh probe in test — there are
# no real CLIs or endpoints to hit. Tests that exercise the prober inject a
# :refresh_fun stub and enable explicitly.
config :arbiter, :cloud_quota_probe, enabled: false

# Disable direct Gemini CLI / Antigravity quota fetching in test — there are no
# real Google credentials or endpoints to hit, so the quota surface stays a pure
# DB read. Tests that exercise the fetch path pass `enabled: true` explicitly and
# stub HTTP with a Req.Test plug.
config :arbiter, :cloud_code_quota, enabled: false

# Direct Codex quota (bd-cqfn5i): point the auth-file read at a path that never
# exists so surface tests (quota_get / GET /api/quota) get the graceful no-op
# and make no real network call. Tests exercising the live path inject
# `credentials:`/`auth_path:` and enable the Req.Test stub explicitly.
config :arbiter, :codex_quota, auth_path: "/nonexistent/codex/auth.json"

# `Arbiter.Quota.CloudCode.antigravity/1` shells out to the `agy` CLI by
# name/path via `:agy_cmd` (default `"agy"`, resolved with
# `System.find_executable/1`). Point the default at a name that can never
# resolve so the suite's quota surface stays a pure no-op instead of shelling
# out to a real ~199 MB `agy` binary on whatever machine happens to have it
# installed. Tests exercising the live path pass `agy_cmd:` (or
# `agy_usage_probe:`) explicitly.
config :arbiter, :agy_cmd, "arbiter-test-nonexistent-agy"

# Disable the fleet credential Watchdog in test — its probe is a real agent-CLI
# round-trip per adapter (`codex exec` in particular bills against the ChatGPT
# session quota), and the suite has no CLIs to hit. Both
# `Arbiter.Agents.CredentialWatchdog`'s moduledoc and its test file already
# assumed this was set; it wasn't, so every `mix test` run was firing live
# probes from the app-started singleton (bd-ajgve2). Tests that need a polling
# Watchdog start their own unnamed instance with `enabled: true`.
config :arbiter, :credential_watchdog, enabled: false

# The board's auto-dispatcher (bd-bqyeqa). Off and never ticking under test:
# a test that resumes the scheduler is exercising the switch, not asking for a
# real worker to be spawned fifteen seconds later.
config :arbiter, :board_autopilot, enabled: false, interval_ms: :never

# Coordinator sessions (bd-bpt0ag). The session socket directory is derived
# from `XDG_RUNTIME_DIR`, which is a real tmpfs on the dogfood host — point it
# at a scratch path under test so nothing in the suite can create a socket
# beside a live session's. Tests that assert on paths override this per test
# with their own `tmp_dir`.
config :arbiter,
       :sessions_runtime_dir,
       Path.join(System.tmp_dir!(), "arbiter-test-sessions-runtime")

# Per-session provisioning scaffolds (bd-aprlbb, RFC §9.1). Under tmp so the
# suite never scaffolds into a real `~/dev/arbiter-sessions`, and — with
# `:primary_checkout` pinned to a path that exists nowhere — so the §10.2
# live-checkout guard is exercised deterministically rather than against
# whatever checkout the developer happens to be running from.
config :arbiter,
       :sessions_root,
       Path.join(System.tmp_dir!(), "arbiter-test-sessions-root")

config :arbiter, :primary_checkout, "/nonexistent/arbiter-primary-checkout"

# Shared memory root (bd-6dkpf1, RFC §9.4). Same reasoning as :sessions_root
# above — under tmp so the suite never mounts the operator's real memory
# files into throwaway session scaffolds.
config :arbiter,
       :memory_root,
       Path.join(System.tmp_dir!(), "arbiter-test-memory-root")

# Mode B copies the operator's real `~/.claude/.credentials.json` into a
# session's config dir — correct in production (§8.2), catastrophic in a test
# suite that provisions dozens of throwaway sessions under tmp. Point the
# source at a directory that does not exist; the tests that exercise seeding
# pass their own source explicitly.
config :arbiter,
       :sessions_credentials_source,
       Path.join(System.tmp_dir!(), "arbiter-test-absent-operator-config")
