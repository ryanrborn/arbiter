defmodule Arbiter.Boot.Migrator do
  @moduledoc """
  Run pending Ecto migrations during application boot, before the endpoint
  accepts traffic.

  Arbiter has no auto-migrator, and neither `mix phx.server` (dev) nor a
  release boot runs migrations on their own. So any boot after new migration
  files land — `mix phx.server`, `arb start`, `arb restart`, `arb update` —
  could otherwise come up against a stale schema and fail at runtime the first
  time it touches a changed table. This child closes that gap: it migrates the
  database to head as a *synchronous* step in the supervision tree.

  ## Why a synchronous child (and not a `Task`)

  The supervisor starts each child by calling its start function and *waiting*
  for the return value. Doing the migration inline in `start_link/1` therefore
  blocks the whole boot until migrations finish, and only then does
  `Arbiter.Application.start/2` return — which is what lets the `:arbiter_web`
  app (and `ArbiterWeb.Endpoint`) start *after* the schema is current.

  A `Task` child (like the reconcile/merge_queue boot tasks) would be the wrong
  tool: a Task is merely *spawned* during boot and runs concurrently, so the
  endpoint could bind its port and serve requests against a half-migrated
  schema. The ordering guarantee we need is exactly the blocking one.

  On success `start_link/1` returns `:ignore` — there is no long-lived process
  to supervise, the migration is a one-shot boot step — so the supervisor
  records nothing and moves on to the next child.

  ## Single-instance gate (bd-9rouwh)

  Running migrations is destructive and must not race. We gate on
  `Arbiter.SingleInstance.primary?/0` — the same advisory-lock verdict the boot
  reconciler consults — so only the one canonical instance per database
  migrates. A concurrent or duplicate boot (a second `mix phx.server` /
  `iex -S mix` while the real server is up) is a SECONDARY and skips migration
  entirely; it never owned the schema and its boot is transient. This requires
  `Arbiter.SingleInstance` to be started *before* this child in the tree (its
  lock is acquired synchronously in `init/1`), which `Arbiter.Application`
  guarantees.

  ## Failing loudly

  A migration failure must fail the boot — a server that came up against a
  schema it could not migrate is not safe to serve traffic. `migrate!/0`
  pattern-matches `Ecto.Migrator.with_repo/2`'s success tuple and
  `Ecto.Migrator.run/3` raises on a bad migration, so any failure propagates
  out of `start_link/1`. The supervisor turns that into a failed child start,
  which aborts `Application.start/2` and crashes the boot with the migration
  error in the logs.

  ## Dev and prod

  `Ecto.Migrator.with_repo/2` works whether or not the repo is already started:
  in the running supervision tree (dev `mix phx.server` and prod release alike)
  `Arbiter.Repo` is started earlier in the tree, so `with_repo/2` finds it
  `:already_started` and reuses the live pool rather than standing up a second
  one. The migration files ship in `priv/repo/migrations` and are packaged into
  the release, so `all: true` finds them in both environments.

  Supersedes any per-command migration logic in `arb start` / `arb restart` /
  `arb update`: migration is now an app-boot concern, owned here.

  ## Built-in skill seeding (bd-503v3d)

  Right after migrations land, the primary instance also runs
  `Arbiter.Skills.Seeds.seed!/0` — insert-if-absent by name, so a fresh install
  (or any subsequent boot) always has the built-in skills registered without an
  operator running `priv/repo/seeds.exs` by hand. Piggybacks on this step
  rather than a parallel boot mechanism because it needs the same
  primary-instance gate and the same "runs on install / first boot /
  migration" timing that migration already has.
  """

  require Logger

  alias Arbiter.SingleInstance

  @doc """
  Child spec for the supervision tree.

  A one-shot worker: `start_link/1` does the migration inline and returns
  `:ignore`, so `restart: :temporary` — there is nothing to restart, and a
  migration failure should abort the boot rather than loop.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Migrate to head if this is the primary instance, otherwise skip.

  Called synchronously by the supervisor during boot. Returns `:ignore` (no
  process to supervise) on success or skip; raises on migration failure so the
  boot fails loudly.

  `:primary?` overrides the `Arbiter.SingleInstance.primary?/0` lookup (for
  tests); it is evaluated here at start time, not when the spec is built, so
  `Arbiter.Application.children/1` stays a pure spec builder.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0) do
      Logger.info("Boot.Migrator: primary instance — running pending migrations")
      migrate!()
      Logger.info("Boot.Migrator: migrations up to date")
      Arbiter.Skills.Seeds.seed!()
    else
      Logger.info("Boot.Migrator: not the primary instance — skipping migrations")
    end

    :ignore
  end

  @doc """
  Run all pending migrations (`:up`) for every configured repo.

  Uses `Ecto.Migrator.with_repo/2` so it works whether or not the repo pool is
  already started. The `{:ok, _, _}` match means a failure to even start the
  repo raises here; `Ecto.Migrator.run/3` raises on a failing migration. Either
  way the caller's boot crashes.
  """
  @spec migrate!() :: :ok
  def migrate! do
    for repo <- Application.fetch_env!(:arbiter, :ecto_repos) do
      {:ok, _migrated_versions, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
