defmodule ArbiterCli.Cmd.ReleaseDeploy do
  @moduledoc """
  `arb server deploy [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]`
  — deploy the Arbiter server from a **GitHub Release** (the OTP release tarball
  published by `.github/workflows/release.yml`), rather than a `git pull` + Mix
  rebuild of a working checkout.

  `arb server deploy --local <tarball|dir>` deploys a **locally built**
  release instead — the tarball or unpacked `_build/prod/rel/arbiter`
  directory produced by `scripts/build-local-release.sh` from a fast-forwarded
  `main`. It shares every step below (unpack, atomic swap, restart,
  health-check, auto-rollback, prune) with the GitHub flow; the only
  difference is where the release tree comes from, and that a local build has
  no published tag or checksum to verify against, so it is assigned a
  synthetic `local-<timestamp>` tag and skips the post-swap version-string
  comparison (which only makes sense against a version GitHub told us to
  expect). `--force`, `--timeout`, `--json`, and
  `--allow-cross-migration-rollback` all work the same with `--local`;
  `--version` is a GitHub-flow-only option and is ignored when `--local` is
  given.

  This is the production deploy path: the box that runs Arbiter no longer needs
  a source checkout or a Mix/Elixir toolchain — only the prebuilt, self-contained
  OTP release. The legacy `git pull` deploy remains available behind
  `arb server deploy --git-pull` until the cutover is complete (see
  `ArbiterCli.Cmd.Update`).

  ## What it does

    1. **Resolve the target release.** Query the GitHub Releases API for
       `latest` (or the tag named by `--version`). The `owner/repo` comes from
       `ARB_RELEASE_REPO`; a `GITHUB_TOKEN`, if set, authenticates the request
       (required for private repos, and lifts the anonymous rate limit).
    2. **Download the asset + checksum.** Fetch `arbiter-<tag>-linux.tar.gz`
       and its `arbiter-<tag>-linux.tar.gz.sha256` sidecar.
    3. **Verify sha256.** Recompute the tarball's SHA-256 and compare it to the
       published checksum. A mismatch aborts before anything touches disk state.
    4. **Unpack** to `<data-home>/releases/<tag>/` (the OTP release tree, so
       `<data-home>/releases/<tag>/bin/arbiter` is the runnable binary).
    5. **Atomically swap** the `<data-home>/current` symlink to the new release
       (symlink-then-rename, so readers never observe a missing/partial link).
    6. **Restart + health-check.** Bounce the service (via systemd when the
       `arbiter.service` user unit is present) and poll `arb doctor` until
       green. Migrations run *here*, inside the new release's own boot — see
       "Migration ordering" below.
    7. **Auto-rollback on failure.** If the stack does not come back green
       within the timeout, re-point `current` at the prior release and restart,
       leaving the server on the last-known-good version. The command then exits
       non-zero so the operator knows the new version was rejected. **Unless
       this deploy crossed a migration** — see "Cross-migration rollback".
    8. **Prune.** Retain the current release plus the 3 most-recent prior
       releases under `<data-home>/releases/`; delete anything older.

  ## Migration ordering (bd-bksulf)

  This command does **not** run migrations. It used to `eval
  Arbiter.Release.migrate` out of the freshly-unpacked release between steps 4
  and 5 — which put a second SQLite *writer* on the database while the old
  server was still serving from it. SQLite allows exactly one writer, and the
  coordinator's own guidance (#754) is that a separate migrate must never run
  against a live server.

  Migration is instead the new release's own boot step:
  `Arbiter.Boot.Migrator` is a synchronous child that migrates to head before
  `ArbiterWeb.Endpoint` binds its port, and it is gated on
  `Arbiter.SingleInstance.primary?/0` so only one node ever migrates. So the
  real ordering is **stop old → (new boots) migrate → serve**, with exactly one
  writer at every instant, and it is the same path dev mode, `arb start`,
  `arb restart` and `arb update` already take. The `Arbiter.Release.migrate`
  eval remains available for an operator who wants to migrate by hand with the
  service stopped.

  ## Cross-migration rollback (bd-bksulf)

  Rolling `current` back to the prior release after the new one has already
  migrated the database puts old code on a schema it has never seen. Before
  swapping, the deploy therefore compares the migrations packaged into the new
  release tree against those in the release it would roll back to
  (`ReleaseFiles.crossed_migrations/2` — a pure filesystem comparison, no DB
  connection). If the new release adds any:

    * the deploy **refuses** to auto-roll back on a health-check failure,
      leaves `current` on the new release, names the crossed migrations, and
      exits non-zero; and
    * `--allow-cross-migration-rollback` overrides that, rolling back anyway
      with a loud warning that the prior release is now on a newer schema.

  A deploy that adds no migrations keeps the automatic rollback exactly as it
  was.

  ## Layout

  All deploy state lives under a data home (default `~/.arbiter`, override with
  `ARB_DATA_HOME`):

      <data-home>/
        current -> releases/v0.1.0      # atomically-swapped symlink
        releases/
          v0.1.0/bin/arbiter
          v0.0.2/bin/arbiter
          …

  The systemd unit is expected to exec `<data-home>/current/bin/arbiter start`,
  so swapping the symlink + restarting is all that's needed to change versions.

  ## Configuration

    * `ARB_RELEASE_REPO` — `owner/repo` to pull releases from (required).
    * `GITHUB_TOKEN` — optional; authenticates the Releases API request.
    * `ARB_DATA_HOME` — deploy root (default `~/.arbiter`).
    * `ARB_GITHUB_API` — Releases API base (default `https://api.github.com`).

  ## Exit codes

    * `0` — the target release was deployed and the stack is green (or it was
      already the current release).
    * `1` — a precondition failed (missing config, API/download error, checksum
      mismatch, unpack failure) **or** the new release failed its health check
      and was rolled back (or had its rollback refused because the deploy
      crossed a migration).
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Cmd.Doctor, Cmd.InstallService, Cmd.Restart, Cmd.Start}
  alias ArbiterCli.Cmd.ReleaseDeploy.{Formatter, Github, ReleaseFiles}
  alias ArbiterCli.Output

  @default_timeout_s 60

  @switches [
    version: :string,
    timeout: :integer,
    json: :boolean,
    force: :boolean,
    local: :string,
    allow_cross_migration_rollback: :boolean
  ]

  @doc "Entry point for `arb server deploy` (release-based path)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn -> do_deploy(argv) end)
  end

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp do_deploy(argv) do
    {opts, _rest, mode} = ArgParser.parse_strict!(argv, "arb server deploy", strict: @switches)
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000
    force = opts[:force] || false

    # A worker must never bounce the orchestrating server, and an in-flight
    # deploy must not abandon active workers. Same guards as `arb restart`.
    Restart.guard_worker_session!()

    case opts[:local] do
      nil -> deploy_from_github(opts, mode, force, timeout_ms)
      path -> deploy_from_local(path, mode, force, timeout_ms, opts)
    end
  end

  # ---- source: published GitHub release ------------------------------------

  defp deploy_from_github(opts, mode, force, timeout_ms) do
    # Resolve the repo first so a misconfiguration fails fast, before we reach
    # for the (HTTP-backed) active-worker check.
    repo = Github.release_repo()
    Restart.guard_active_workers!(force)

    release = Github.fetch_release(repo, opts[:version])
    tag = Github.release_tag(release)

    populate = fn target_dir ->
      {tarball_url, sha_url} = Github.release_assets(release, tag)

      log("Downloading #{Github.asset_name(tag)} from #{repo}@#{tag}…")
      tarball = Github.download_binary(tarball_url)
      expected_sha = Github.parse_sha256(Github.download_binary(sha_url))

      Github.verify_sha256!(tarball, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      ReleaseFiles.unpack!(tarball, target_dir)
    end

    deploy(tag, populate, mode, force, timeout_ms, opts)
  end

  # ---- source: locally-built release (bd-bbgw7k) ----------------------------

  # A locally-built release has no GitHub tag, so it gets a synthetic one:
  # `local-<timestamp>`, unique per invocation so two local deploys never
  # collide on the same release directory (and the idempotency short-circuit
  # below is effectively a no-op for this source — every local deploy is
  # treated as a new release).
  defp deploy_from_local(path, mode, force, timeout_ms, opts) do
    Restart.guard_active_workers!(force)

    unless File.exists?(path) do
      Output.die("--local path does not exist: #{path}")
    end

    tag = "local-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    populate = fn target_dir ->
      if File.dir?(path) do
        log("Installing local release directory #{path}…")
        ReleaseFiles.install_dir!(path, target_dir)
      else
        log("Installing local release tarball #{path}…")
        ReleaseFiles.unpack!(File.read!(path), target_dir)
      end

      unless File.exists?(Path.join(target_dir, "bin/arbiter")) do
        Output.die(
          "#{path} does not look like an OTP release",
          "expected #{Path.join(target_dir, "bin/arbiter")} to exist after install."
        )
      end
    end

    deploy(tag, populate, mode, force, timeout_ms, opts)
  end

  # ---- shared install/swap/rollback path ------------------------------------
  #
  # Both sources share every step from here on — the unpack/swap/prune/rollback
  # machinery has exactly one implementation regardless of where the release
  # tree came from. `populate.(target_dir)` is the only source-specific step:
  # it must leave a fully-formed release under `target_dir` (or raise/die).
  defp deploy(tag, populate, mode, force, timeout_ms, opts) do
    releases_dir = ReleaseFiles.releases_dir()
    target_dir = Path.join(releases_dir, tag)
    current_link = ReleaseFiles.current_link()

    # Idempotency: if `current` already points at this tag, there's nothing to
    # do unless the operator forces a redeploy.
    if not force and ReleaseFiles.current_target_basename(current_link) == tag do
      Formatter.emit_already_current(mode, tag)
    else
      # Snapshot doctor state before touching anything, so a readiness-blocking
      # check that's already red (pre-existing condition) is distinguishable from
      # one caused by the release being deployed. Without this, a timed-out
      # green-wait reads identically whether the new release is unhealthy or
      # the stack was already broken before this deploy started. Deferred
      # until after the idempotency check so a no-op `arb server deploy`
      # doesn't pay for it or warn about a deploy that never happens.
      pre_deploy_fails = preflight_blocking_fails()

      if pre_deploy_fails != [] do
        log(preflight_warning(pre_deploy_fails, tag))
      end

      populate.(target_dir)

      # Refresh the PATH in arbiter.env from the deploying shell before
      # restarting the service. The EnvironmentFile= directive loads this file,
      # so any stale or test-corrupted PATH= line here would break every worker
      # spawn after the restart. Writing now ensures the service always boots
      # with the same PATH the operator used to invoke this deploy.
      refresh_env_path()
      preflight_claude_path()

      prior_target = ReleaseFiles.current_target(current_link)

      # Decide the rollback policy *before* the swap, while both release trees
      # are still on disk and nothing has migrated yet.
      rollback_plan =
        rollback_plan(target_dir, prior_target, opts[:allow_cross_migration_rollback] || false)

      case migration_notice(rollback_plan, tag) do
        nil -> :ok
        notice -> log(notice)
      end

      ReleaseFiles.atomic_symlink_swap!(current_link, target_dir)
      log("Swapped #{current_link} -> #{target_dir}")

      case Restart.perform(ReleaseFiles.restart_root(current_link), timeout_ms) do
        {:ok, actions, was_running} ->
          case verify_deployed_version(tag) do
            :ok ->
              pruned = ReleaseFiles.prune_old_releases(releases_dir, target_dir, prior_target)

              Formatter.emit_deployed(
                mode,
                tag,
                ReleaseFiles.prior_basename(prior_target),
                actions,
                was_running,
                pruned
              )

            {:mismatch, server_vsn} ->
              outcome = auto_rollback(current_link, rollback_plan, timeout_ms)
              Formatter.emit_swap_failed(mode, tag, server_vsn, outcome)

            :inconclusive ->
              # Doctor already confirmed Phoenix is reachable (a fatal check),
              # so a failure here is a transient /api/version hiccup, not
              # evidence the swap failed — don't roll back a healthy deploy on
              # a flaky read of a non-fatal endpoint.
              pruned = ReleaseFiles.prune_old_releases(releases_dir, target_dir, prior_target)

              Formatter.emit_deployed(
                mode,
                tag,
                ReleaseFiles.prior_basename(prior_target),
                actions,
                was_running,
                pruned
              )
          end

        {:timeout, _actions, _was_running} ->
          outcome = auto_rollback(current_link, rollback_plan, timeout_ms)
          Formatter.emit_rollback(mode, tag, outcome, timeout_ms, pre_deploy_fails)
      end
    end
  end

  # ---- post-swap version verification --------------------------------------

  # Distinguishes the two mismatch cases from bd-a3t4ao: a stale local CLI is
  # normal and must never gate rollback (that's `Doctor`'s non-fatal `version`
  # check); but here, right after a swap we just performed ourselves, we know
  # exactly which version *should* be running — so a server that reports
  # anything else is a failed swap, and that must roll back.
  # Local builds carry whatever version `mix.exs` derives at build time (the
  # nearest git tag, per its `@version` fallback) — not a version stamped
  # after the tag we made up in `deploy_from_local/3`. There is nothing
  # meaningful to compare, so skip straight to trusting the health check that
  # already gated this call.
  defp verify_deployed_version("local-" <> _), do: :ok

  defp verify_deployed_version(tag) do
    expected_vsn = String.trim_leading(tag, "v")

    case ArbiterCli.Client.get("/api/version") do
      {:ok, %{"version" => server_vsn}} when server_vsn == expected_vsn ->
        :ok

      {:ok, %{"version" => server_vsn}} ->
        {:mismatch, server_vsn}

      {:error, _} ->
        :inconclusive
    end
  end

  # ---- pre-flight -----------------------------------------------------------

  # Names of every currently-red readiness-blocking doctor check, queried
  # against whatever is running *before* this deploy touches anything. Uses
  # `blocks_readiness`, not `fatal` — `fatal` also drives `arb doctor`'s exit
  # code and includes checks (like workspace resolution) that are
  # operator-actionable but have no bearing on whether the green-wait below
  # will time out. Flagging those here would reintroduce a milder version of
  # bd-8ix2tw: a misleading "pre-existing condition" note on a deploy that
  # was never at risk of it.
  defp preflight_blocking_fails do
    Doctor.checks()
    |> Enum.filter(&(&1.status == :fail and &1.blocks_readiness))
    |> Enum.map(& &1.name)
  end

  @doc false
  # Extracted (rather than inlined at the call site) and left public so its
  # content is directly assertable in tests — the `log/1` call it feeds is a
  # no-op whenever `:bd2_sleep` is stubbed, which every deploy test does.
  def preflight_warning(pre_deploy_fails, tag) do
    "warning: #{length(pre_deploy_fails)} readiness-blocking health check(s) already " <>
      "failing before this deploy started (#{Enum.join(pre_deploy_fails, ", ")}). Run " <>
      "`arb doctor` to investigate — if this deploy times out waiting for green, " <>
      "that pre-existing condition, not release #{tag}, may be why."
  end

  # ---- rollback -----------------------------------------------------------

  @typedoc """
  What an automatic rollback would do, decided before the symlink swap:

    * `:prior_target` — the release dir to fall back to, or `nil` when there is
      none (a failed first-ever deploy).
    * `:crossed` — migrations the new release ships that `prior_target` does
      not, i.e. the ones a rollback would strand. Always `[]` when
      `prior_target` is `nil`.
    * `:detected` — we actually found migrations packaged in the new release
      tree. An arbiter release always ships some (72 and counting), so an empty
      set means the detection globs no longer match the release layout, not
      that the deploy is migration-free. `crossed: []` is only trustworthy when
      this is true.
    * `:allow_crossed` — the operator passed `--allow-cross-migration-rollback`.
  """
  @type rollback_plan :: %{
          prior_target: String.t() | nil,
          crossed: [String.t()],
          detected: boolean(),
          allow_crossed: boolean()
        }

  @spec rollback_plan(String.t(), String.t() | nil, boolean()) :: rollback_plan()
  defp rollback_plan(target_dir, prior_target, allow_crossed) do
    %{
      prior_target: prior_target,
      crossed: ReleaseFiles.crossed_migrations(target_dir, prior_target),
      detected: ReleaseFiles.migrations(target_dir) != %{},
      allow_crossed: allow_crossed
    }
  end

  @doc false
  # The pre-swap notice for this plan, or nil when there is nothing to say.
  # Public for the same reason as `cross_migration_notice/2`.
  @spec migration_notice(rollback_plan(), String.t()) :: String.t() | nil
  def migration_notice(%{crossed: crossed} = plan, tag) when crossed != [],
    do: cross_migration_notice(plan, tag)

  def migration_notice(%{detected: false} = plan, tag),
    do: undetected_migrations_notice(plan, tag)

  def migration_notice(_plan, _tag), do: nil

  @doc false
  @spec undetected_migrations_notice(rollback_plan(), String.t()) :: String.t()
  def undetected_migrations_notice(%{allow_crossed: allow_crossed}, tag) do
    head =
      "warning: found no migrations packaged in release #{tag} " <>
        "(#{Enum.join(ReleaseFiles.migration_globs(), ", ")}). An arbiter release always " <>
        "ships migrations, so this almost certainly means the release layout moved and " <>
        "cross-migration detection is broken — not that this deploy is migration-free."

    if allow_crossed do
      head <>
        " --allow-cross-migration-rollback was passed, so a health-check failure will still " <>
        "roll back, possibly onto a migrated schema."
    else
      head <> " Automatic rollback is therefore disabled for this deploy."
    end
  end

  @doc false
  # Extracted and left public so its content is directly assertable — the
  # `log/1` call it feeds is a no-op whenever `:bd2_sleep` is stubbed, which
  # every deploy test does.
  @spec cross_migration_notice(rollback_plan(), String.t()) :: String.t()
  def cross_migration_notice(%{crossed: crossed, allow_crossed: allow_crossed}, tag) do
    head =
      "note: release #{tag} adds #{length(crossed)} migration(s) the current release does " <>
        "not ship (#{Enum.join(crossed, ", ")}). They apply during the new release's boot."

    if allow_crossed do
      head <>
        " --allow-cross-migration-rollback was passed, so a health-check failure will still " <>
        "roll back — onto the migrated schema."
    else
      head <> " Automatic rollback is therefore disabled for this deploy."
    end
  end

  # Re-point `current` at the prior release and restart.
  #
  # Returns one of:
  #
  #   * `{:rolled_back, prior_tag, crossed}` — `current` is back on the prior
  #     release. `crossed` is non-empty only when the operator forced it.
  #   * `{:no_prior, nil, []}` — nothing to roll back to.
  #   * `{:refused, prior_tag, crossed}` — the deploy crossed migrations, so
  #     `current` was deliberately left on the new release (bd-bksulf). Booting
  #     `prior_tag` now would run its code against a schema it has never seen,
  #     which is a data-safety decision an operator has to make explicitly.
  #   * `{:undetected, prior_tag, []}` — we could not read the new release's
  #     migrations at all, so the rollback cannot be *proven* safe. Fails closed
  #     the same way as `:refused`, because a detection glob that stopped
  #     matching reports "nothing crossed" for every deploy forever.
  @spec auto_rollback(String.t(), rollback_plan(), non_neg_integer()) ::
          {:rolled_back | :refused | :undetected, String.t(), [String.t()]}
          | {:no_prior, nil, []}
  defp auto_rollback(_current_link, %{prior_target: nil}, _timeout_ms), do: {:no_prior, nil, []}

  defp auto_rollback(current_link, plan, timeout_ms) do
    %{prior_target: prior_target, crossed: crossed, allow_crossed: allow_crossed} = plan
    prior_tag = Path.basename(prior_target)

    case {rollback_decision(plan), allow_crossed} do
      {:safe, _} ->
        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, []}

      {:crossed, true} ->
        log(
          "Health check failed and this deploy crossed #{length(crossed)} migration(s) — " <>
            "rolling back anyway because --allow-cross-migration-rollback was passed."
        )

        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, crossed}

      {:crossed, false} ->
        log(
          "Health check failed, but this deploy crossed #{length(crossed)} migration(s) — " <>
            "refusing to roll back to #{prior_tag} automatically."
        )

        {:refused, prior_tag, crossed}

      {:undetected, true} ->
        log(
          "Health check failed and the new release's migrations could not be read — " <>
            "rolling back anyway because --allow-cross-migration-rollback was passed."
        )

        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, []}

      {:undetected, false} ->
        log(
          "Health check failed, but the new release's migrations could not be read — " <>
            "refusing to roll back to #{prior_tag} automatically (cannot prove the " <>
            "rollback would not strand a migration)."
        )

        {:undetected, prior_tag, []}
    end
  end

  # What the automatic rollback is allowed to do, from the plan alone:
  #
  #   * `:safe` — the prior release ships every migration the new one does.
  #   * `:crossed` — the new release adds migrations the prior lacks.
  #   * `:undetected` — the new release's migration set came back empty, which
  #     for arbiter means detection broke. Never report that as `:safe`: a
  #     silent detection failure re-arms exactly the mixed-schema rollback this
  #     guard exists to prevent.
  @spec rollback_decision(rollback_plan()) :: :safe | :crossed | :undetected
  defp rollback_decision(%{crossed: [], detected: true}), do: :safe
  defp rollback_decision(%{crossed: []}), do: :undetected
  defp rollback_decision(_plan), do: :crossed

  defp perform_rollback(current_link, prior_target, timeout_ms) do
    log("Health check failed — rolling back to #{Path.basename(prior_target)}…")
    ReleaseFiles.atomic_symlink_swap!(current_link, prior_target)
    # Best-effort: bring the prior release back up. We report whatever doctor
    # says afterwards rather than gating the rollback on a fresh green wait.
    _ = Restart.perform(ReleaseFiles.restart_root(current_link), timeout_ms)
    :ok
  end

  # ---- env refresh --------------------------------------------------------

  # Write the deploying shell's PATH into arbiter.env so the restarted service
  # inherits a working PATH (one that finds claude, arb, mise shims, etc.).
  # Idempotent: uses the same read/merge/write logic as `arb install service`.
  defp refresh_env_path do
    home = ReleaseFiles.data_home()

    case InstallService.capture_path(home) do
      :written -> log("Refreshed PATH in #{home}/arbiter.env.")
      :skipped -> :ok
    end
  end

  # Verify that `claude` is resolvable after the deploy.  The check runs against
  # the PATH visible to the deploy process — the same PATH that was just written
  # into arbiter.env — so a missing claude is caught before callers block on a
  # failing dispatch.
  defp preflight_claude_path do
    case System.find_executable("claude") do
      nil ->
        log(
          "warning: `claude` not found on PATH (#{System.get_env("PATH", "")}). " <>
            "Worker spawns will fail. Add claude's directory to your shell PATH " <>
            "and re-run `arb install service` to persist it."
        )

        false

      _path ->
        true
    end
  end

  # Progress chatter, routed through the same seam as `arb start`/`arb restart`
  # so it stays quiet under test and on `--json`.
  defp log(msg), do: Start.log_text(msg)
end
