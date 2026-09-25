defmodule Arbiter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Arbiter.Workflows.DispatchQueueSupervisor
  alias Arbiter.Workflows.MergedPRFinalizerSupervisor
  alias Arbiter.Workflows.MergeQueueSupervisor
  alias Arbiter.Workflows.PRPatrolSupervisor
  alias Arbiter.Workflows.ReviewPatrolSupervisor

  @impl true
  def start(_type, _args) do
    children = children(auto_start?: MergeQueueSupervisor.auto_start?())

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbiter.Supervisor)
  end

  @doc """
  Build the application's full child spec list.

  `:auto_start?` controls whether the gated boot Tasks (orphan-run
  reconciliation and merge_queue enumeration) are appended. `start/2` mirrors
  `MergeQueueSupervisor.auto_start?()` here — false in `test`, true everywhere
  else — so the boot Tasks don't race the sandboxed DB connection.

  This is a pure function (it builds specs, it starts nothing) so a test can
  resolve the *full* boot wiring with `auto_start?: true` and assert every
  child id is unique. That guard matters because the boot Tasks are gated off
  in test: a duplicate child id between them is otherwise invisible to the
  green suite and only surfaces as a real dev/prod boot crash ("more than one
  child specification has the id: Task"). See `Arbiter.ApplicationTest`.
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children(opts \\ []) do
    auto_start? = Keyword.get(opts, :auto_start?, MergeQueueSupervisor.auto_start?())

    [
      Arbiter.Repo,
      # Cloak vault for encrypting workspace secrets at rest. Started early (it
      # has no deps) and resolves ARBITER_CLOAK_KEY in its init — a missing key
      # aborts the boot here, before any workspace read can hit an encrypted
      # column. See Arbiter.Vault.
      Arbiter.Vault,
      {DNSCluster, query: Application.get_env(:arbiter, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Arbiter.PubSub},
      # Shared, priority-aware GitHub request budget (bd-3p5vqc). Keyed on pool
      # identity (the account owning a credential), it reserves headroom so
      # background patrol traffic can never starve foreground work — a deploy,
      # dispatch, PR open/merge/finalize, or tracker transition. Started early
      # (no deps) so every GitHub-calling path can gate through it. See
      # Arbiter.GitHub.Limiter.
      {Task.Supervisor, name: Arbiter.TaskSupervisor},
      # The shared circuit breaker (bd-5jr49o). Started early and with no deps
      # so every auto-filing / auto-escalating / auto-redispatching path can
      # gate through it; callers fail open if it is somehow absent.
      Arbiter.CircuitBreaker,
      Arbiter.GitHub.Limiter,
      Arbiter.Agents.ProviderPool,
      # bd-21bmdh: the auth-shaped dispatch hold. Pure bookkeeping (no probes,
      # no I/O), so the dispatch guard's fail-closed read of it never blocks.
      Arbiter.Agents.AuthHold,
      Arbiter.Agents.CredentialWatchdog,
      {Registry, keys: :unique, name: Arbiter.Worker.Registry},
      # bd-9fgg04: live agent work that runs outside Arbiter.Worker.Supervisor
      # (a dispatch still provisioning, a PR review/reply shelling out to the
      # agent CLI) registers here for its duration — see Arbiter.Board.Drain.
      {Registry, keys: :unique, name: Arbiter.Board.Drain.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Worker.Supervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Worker.WatchdogSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.MachineRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Workflows.MachineSupervisor},
      {Registry, keys: :unique, name: Arbiter.Workflows.MergeQueueRegistry},
      # Runs background external-PR reviews (`arb review --pr`) off the request
      # path: the CLI/MCP call returns a "dispatched" ack immediately while the
      # CodeReview adapter workflow posts findings + a verdict to the PR.
      {Task.Supervisor, name: Arbiter.Reviews.TaskSupervisor},
      # Periodic background resolver that walks non-terminal ExternalReview
      # records and refreshes their pr_state (bd-3jjk0e), so the Review History
      # panel stays accurate even when no dashboard LiveView is open. The
      # dashboard is a reader of pr_state; this is the writer of record.
      Arbiter.Reviews.PrStatePoller,
      # Transitions abandoned ExternalReview records out of :running (bd-4vc2bo).
      # A reviewer process that dies mid-flight (killed, crashed, host restart)
      # never writes the terminal update, so without this the row sits at
      # :running forever and external_review_list(status: "running") overstates
      # what's actually in flight. See Arbiter.Reviews.StaleReviewReaper.
      Arbiter.Reviews.StaleReviewReaper,
      # Re-arms the merge of approved PRs whose owning worker exited while the
      # merge was waiting on CI / a draft / a transient forge refusal
      # (bd-a370ak / #2002). Reads the durable `issues.pending_merge` stamp, so
      # its first sweep after boot is also what picks a pending merge back up
      # across a restart. Primary-instance only; disabled in test. See
      # Arbiter.Workflows.PendingMergeSweeper.
      Arbiter.Workflows.PendingMergeSweeper,
      # Owns the ETS table backing P3 shadow mode's since-boot counters and
      # its report-once dedup set (#1635 §6.3). Inert until
      # `Arbiter.Reviews.CoverageShadow.observe/1` is called from a merge
      # guard, and never on the merge path itself — every read and write is
      # a direct public-table operation, not a call into this process.
      Arbiter.Reviews.CoverageShadow.Tally,
      # Judges any running Stage 3 routing canary and reverts it automatically
      # if first-pass convergence regressed (bd-6edc0u). Inert for every
      # workspace that has not set `loop.autonomous_routing_enabled`, which is
      # all of them by default.
      Arbiter.Loop.CanaryTicker,
      # bd-8j9i9p: pages the coordinator once when an open task's worker spend
      # crosses its estimate group's p90. Informational — it stops nothing.
      Arbiter.Usage.BudgetPatrol,
      # Prunes `Arbiter.Events.Record` rows past the retention window
      # (bd-73bfml) so the durable log backing `GET /events?since=` doesn't
      # grow without bound. See `Arbiter.Events.Retention` for config.
      Arbiter.Events.Retention,
      # Meters the coordinator's OWN Claude Code sessions (bd-be804c) by
      # sweeping the session JSONLs the CLI writes to disk, and writing the
      # per-session delta as `source: :coordinator_session`. Inert until an
      # install names its session directories
      # (`ARBITER_COORDINATOR_SESSION_DIRS`), and inert in test. See
      # `Arbiter.Sessions.UsageIngest`.
      Arbiter.Sessions.UsageIngest,
      # Touches arbiter's own liveness file (bd-3qkbch, phase 10, §4.6.3) so
      # every session's in-scope dead-man's switch can tell whether arbiter is
      # around without ever connecting to it. Inert wherever
      # XDG_RUNTIME_DIR is unset. See Arbiter.Sessions.Heartbeat.
      Arbiter.Sessions.Heartbeat,
      # Idle-TTL sweep (bd-3qkbch, phase 10, §4.6 item 2): terminates
      # coordinator sessions with no client or turn activity for
      # `:idle_ttl_ms` (default 24h), unless pinned `keep_alive`. See
      # Arbiter.Sessions.IdleReaper.
      Arbiter.Sessions.IdleReaper,
      # Kill-after-grace policy for orphan scopes (bd-3qkbch, phase 10, §4.6
      # item 1): re-sweeps `Arbiter.Sessions.Adoption` periodically and kills
      # an orphan only once it has persisted across a full grace window —
      # never on the sweep that first notices it. See
      # Arbiter.Sessions.OrphanReaper.
      Arbiter.Sessions.OrphanReaper,
      # Deletes a session's persisted raw transcript once it has been :ended
      # past the retention window (phase 9, RFC §11). See
      # Arbiter.Sessions.TranscriptRetention.
      Arbiter.Sessions.TranscriptRetention,
      # Terminal transport for browser-hosted coordinator sessions (bd-3ymdvi,
      # phase 4). One `Arbiter.Sessions.Stream` reader per *attached* session,
      # started on first attach and stopped when the last client leaves — so
      # the tree holds only the registry and a dynamic supervisor, never a
      # handle on a session. A reader dying (or this whole app restarting)
      # drops the reader, never the tmux session: that lives in its own
      # systemd scope, which is the property phases 1-2 exist to protect.
      {Registry, keys: :unique, name: Arbiter.Sessions.Stream.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Sessions.Stream.Supervisor},
      # Post-spawn connectivity probe for Codex's `.codex/config.toml` MCP config
      # (bd-bi5t54). Codex MCP support has reports of *silent* connect failures —
      # it starts without error but never reaches the MCP server — so a worker
      # dispatch fires this off the dispatch path right after injecting the
      # config, rather than requiring live debugging to notice a wedged worker.
      {Task.Supervisor, name: Arbiter.Worker.MCPVerifySupervisor},
      MergeQueueSupervisor,
      {Registry, keys: :unique, name: Arbiter.Workflows.PRPatrolRegistry},
      PRPatrolSupervisor,
      {Registry, keys: :unique, name: Arbiter.Workflows.ReviewPatrolRegistry},
      ReviewPatrolSupervisor,
      # Event-driven half of lazy patrolling (bd-7tr11p): subscribes to task
      # lifecycle and starts a patrol when a repo gains its first fleet PR /
      # engagement, and reaps one when its last watched item closes — so a
      # newly-opened engagement resurrects a patrol with no server restart.
      # Inert in test (auto_start? false → does not subscribe). Placed after both
      # patrol supervisors + registries so they exist when it reacts.
      Arbiter.Workflows.PatrolLifecycle,
      # Ends a refine session when its bound issue is promoted or closed
      # (bd-cvfjms, child 4 of epic bd-cksar2): subscribes to the same
      # `"tasks"` topic as `PatrolLifecycle` above and shares its
      # `:auto_start_refineries` gate for the same reason — inert in test so
      # a global instance never touches an issue/session outside whatever
      # sandbox connection a given test allowed it. See
      # Arbiter.Sessions.RefineLifecycle.
      Arbiter.Sessions.RefineLifecycle,
      {Registry, keys: :unique, name: Arbiter.Workflows.MergedPRFinalizerRegistry},
      MergedPRFinalizerSupervisor,
      # Per-workspace quota-aware dispatch queues (bd-7cd38f). Holds dispatches
      # near the 5h cap and drains them as headroom frees; also carries the
      # per-workspace overage-alert debounce state for :continue mode.
      {Registry, keys: :unique, name: Arbiter.Workflows.DispatchQueueRegistry},
      # Runs each drained dispatch off the DispatchQueue GenServer's process so a
      # slow dispatch (repo resolution, preflight, worker spawn, DB writes)
      # doesn't block the queue — and any concurrent hold/4 / record_overage/3 —
      # for its duration (bd-7cd38f, reviewer round 1 finding 3).
      {Task.Supervisor, name: Arbiter.Workflows.DispatchDrainSupervisor},
      DispatchQueueSupervisor,
      # Periodic refresh of every quota provider (bd-atyrrq: Anthropic's own
      # `/api/oauth/usage` poll now drives the primary + long-window columns
      # `Arbiter.Quota.Gate` reads, alongside Codex, Gemini CLI, and
      # Antigravity, which have no passive proxy signal — bd-ajh7bd). Each
      # cycle fetches per workspace, upserts the persisted snapshot, and
      # broadcasts a quota_updated event so the web dashboard updates live,
      # `GET /api/quota` stays a pure DB read, and any held DispatchQueue
      # intents drain.
      {Task.Supervisor, name: Arbiter.Quota.CloudProbeSupervisor},
      Arbiter.Quota.CloudProbe,
      # The board's Ready queue drains itself (bd-bqyeqa). Paused unless the
      # install opts in with `config :arbiter, :board_autopilot, enabled: true`
      # — auto-dispatch spends money, so an upgrade must not discover it by
      # finding four agents running.
      Arbiter.Board.Autopilot
    ] ++ boot_tasks(auto_start?)
  end

  # The gated boot children. The two `Task` children each MUST carry a distinct
  # explicit `:id` — without one they both collapse to the default `:Task` id
  # and the whole app fails to boot ("more than one child specification has the
  # id: Task").
  #
  #   * SingleInstance: hold a session advisory lock that identifies the one
  #     canonical instance per DB. Started FIRST (and synchronously, via its
  #     init) so the migrator and reconcile Task below can read its verdict.
  #     See bd-9rouwh.
  #   * migrator: run pending Ecto migrations to head, SYNCHRONOUSLY, before any
  #     later child (or the :arbiter_web endpoint) comes up against a stale
  #     schema. Gated on the SingleInstance primary verdict so only the one
  #     canonical instance migrates. A migration failure aborts the boot. Placed
  #     before reconcile/merge_queue so those run against the current schema. It is
  #     a one-shot worker (returns :ignore), not a Task, precisely so it BLOCKS
  #     the boot until the schema is current. See Arbiter.Boot.Migrator.
  #   * config_migrator: run workspace-config DATA migrations (config lives in a
  #     JSON column, so Ecto migrations never touch it) once the schema is at
  #     head — currently the retired `rig_paths` -> `repo_paths` key rename.
  #     Same primary-instance gate and same synchronous one-shot shape as the
  #     migrator, and placed right after it so every later child (patrols,
  #     queues) enumerates workspaces whose repo config is already current.
  #     See Arbiter.Boot.ConfigMigrator and bd-3pqzsa.
  #   * reconcile: sweep orphaned :running worker_runs left behind by a node
  #     that died mid-run. Runs once after Repo + Worker.Registry are online —
  #     but ONLY on the primary instance, so a transient/duplicate boot can't
  #     fail the live instance's running runs.
  #   * reconcile_shutdown_casualties: re-stamp runs the previous node's stop
  #     failed :machine_died as :interrupted, so the resume sweep below picks
  #     them up with their slot held (bd-146u20 / #2053).
  #   * reconcile_open_prs: find :in_progress tasks with a pr_ref but no live
  #     worker — the server was killed between `arb done` and the Watchdog being
  #     established. Escalates each to the coordinator. bd-crqku8.
  #   * session_adoption: reconcile the `sessions` table against the coordinator
  #     sessions systemd and tmux still have running (bd-bpt0ag, RFC §4.6). This
  #     is the ONLY thing that reconnects Arbiter to a session after a restart —
  #     nothing in the BEAM holds a handle to one, by design — so it doubles as
  #     the reattach path and as orphan detection. Primary-gated: a duplicate
  #     boot must not mark the live instance's sessions ended. It never kills an
  #     unrecognised live scope; see Arbiter.Sessions.Adoption.
  #   * merge_queue: eagerly start one MergeQueue per existing workspace once the
  #     tree is up, so a cold boot misses no `:worker_done` events.
  #
  # Gated off in test (auto_start?/0 is false) so the boot sweep doesn't race
  # the sandboxed connection and test code can drive the GenServers with its
  # own stubs. That gating is exactly why an id collision here is invisible to
  # the suite — `Arbiter.ApplicationTest` forces `auto_start?: true` to close
  # the gap.
  defp boot_tasks(false), do: []

  defp boot_tasks(true) do
    [
      Arbiter.SingleInstance,
      Arbiter.Boot.Migrator,
      Arbiter.Boot.ConfigMigrator,
      Supervisor.child_spec(
        {Task,
         fn ->
           primary? = Arbiter.SingleInstance.primary?()
           Arbiter.Workers.Reconciler.reconcile_orphaned_runs(primary?: primary?)
           Arbiter.Workers.Reconciler.reconcile_shutdown_casualties(primary?: primary?)
           Arbiter.Workers.Reconciler.reconcile_open_pr_tasks(primary?: primary?)
           Arbiter.Workers.Reconciler.reconcile_resumable_tasks(primary?: primary?)
         end},
        id: :reconcile_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           primary? = Arbiter.SingleInstance.primary?()
           Arbiter.Sessions.Adoption.sweep_on_boot(primary?: primary?)
         end},
        id: :session_adoption_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> MergeQueueSupervisor.start_for_existing_workspaces() end},
        id: :merge_queue_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> PRPatrolSupervisor.start_for_existing_workspaces() end},
        id: :pr_patrol_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> ReviewPatrolSupervisor.start_for_existing_workspaces() end},
        id: :review_patrol_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> MergedPRFinalizerSupervisor.start_for_existing_workspaces() end},
        id: :merged_pr_finalizer_boot_task,
        restart: :temporary
      ),
      Supervisor.child_spec(
        {Task, fn -> DispatchQueueSupervisor.start_for_existing_workspaces() end},
        id: :dispatch_queue_boot_task,
        restart: :temporary
      )
    ]
  end
end
