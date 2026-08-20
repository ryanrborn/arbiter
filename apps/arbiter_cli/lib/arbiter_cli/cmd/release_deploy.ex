defmodule ArbiterCli.Cmd.ReleaseDeploy do
  @moduledoc """
  `arb server deploy [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]`
  — deploy the Arbiter server from a **GitHub Release** (the OTP release tarball
  published by `.github/workflows/release.yml`), rather than a `git pull` + Mix
  rebuild of a working checkout.

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
    5. **Migrate.** Run `bin/arbiter eval Arbiter.Release.migrate` from the
       freshly-unpacked release — schema changes land before the new code takes
       over serving traffic.
    6. **Atomically swap** the `<data-home>/current` symlink to the new release
       (symlink-then-rename, so readers never observe a missing/partial link).
    7. **Restart + health-check.** Bounce the service (via systemd when the
       `arbiter.service` user unit is present) and poll `arb doctor` until green.
    8. **Auto-rollback on failure.** If the stack does not come back green
       within the timeout, re-point `current` at the prior release and restart,
       leaving the server on the last-known-good version. The command then exits
       non-zero so the operator knows the new version was rejected.
    9. **Prune.** Retain the current release plus the 3 most-recent prior
       releases under `<data-home>/releases/`; delete anything older.

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
      mismatch, unpack/migrate failure) **or** the new release failed its health
      check and was rolled back.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.Cmd.ReleaseDeploy.{Formatter, Github, ReleaseFiles}
  alias ArbiterCli.{Cmd.Doctor, Cmd.InstallService, Cmd.Restart, Cmd.Start}

  @default_timeout_s 60

  @switches [version: :string, timeout: :integer, json: :boolean, force: :boolean]

  @doc "Entry point for `arb server deploy` (release-based path)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn -> do_deploy(argv) end)
  end

  defp do_deploy(argv) do
    {opts, _rest, mode} = ArgParser.parse_strict!(argv, "arb server deploy", strict: @switches)
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000
    force = opts[:force] || false

    # A worker must never bounce the orchestrating server, and an in-flight
    # deploy must not abandon active workers. Same guards as `arb restart`.
    # Resolve the repo first so a misconfiguration fails fast, before we reach
    # for the (HTTP-backed) active-worker check.
    Restart.guard_worker_session!()
    repo = Github.release_repo()
    Restart.guard_active_workers!(force)

    release = Github.fetch_release(repo, opts[:version])
    tag = Github.release_tag(release)

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

      {tarball_url, sha_url} = Github.release_assets(release, tag)

      log("Downloading #{Github.asset_name(tag)} from #{repo}@#{tag}…")
      tarball = Github.download_binary(tarball_url)
      expected_sha = Github.parse_sha256(Github.download_binary(sha_url))

      Github.verify_sha256!(tarball, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      ReleaseFiles.unpack!(tarball, target_dir)
      ReleaseFiles.run_migrations!(target_dir)

      # Refresh the PATH in arbiter.env from the deploying shell before
      # restarting the service. The EnvironmentFile= directive loads this file,
      # so any stale or test-corrupted PATH= line here would break every worker
      # spawn after the restart. Writing now ensures the service always boots
      # with the same PATH the operator used to invoke this deploy.
      refresh_env_path()
      preflight_claude_path()

      prior_target = ReleaseFiles.current_target(current_link)
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
              rolled_back = auto_rollback(current_link, prior_target, timeout_ms)
              Formatter.emit_swap_failed(mode, tag, server_vsn, rolled_back)

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
          rolled_back = auto_rollback(current_link, prior_target, timeout_ms)
          Formatter.emit_rollback(mode, tag, rolled_back, timeout_ms, pre_deploy_fails)
      end
    end
  end

  # ---- post-swap version verification --------------------------------------

  # Distinguishes the two mismatch cases from bd-a3t4ao: a stale local CLI is
  # normal and must never gate rollback (that's `Doctor`'s non-fatal `version`
  # check); but here, right after a swap we just performed ourselves, we know
  # exactly which version *should* be running — so a server that reports
  # anything else is a failed swap, and that must roll back.
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

  # Re-point `current` at the prior release and restart. Returns the prior tag
  # on success, or nil when there was no prior release to fall back to (e.g. a
  # failed first-ever deploy — nothing to roll back to).
  defp auto_rollback(_current_link, nil, _timeout_ms), do: nil

  defp auto_rollback(current_link, prior_target, timeout_ms) do
    log("Health check failed — rolling back to #{Path.basename(prior_target)}…")
    ReleaseFiles.atomic_symlink_swap!(current_link, prior_target)
    # Best-effort: bring the prior release back up. We report whatever doctor
    # says afterwards rather than gating the rollback on a fresh green wait.
    _ = Restart.perform(ReleaseFiles.restart_root(current_link), timeout_ms)
    Path.basename(prior_target)
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
