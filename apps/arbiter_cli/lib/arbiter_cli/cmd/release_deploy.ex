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

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.InstallService, Cmd.Restart, Cmd.Start, Output}

  # How many *prior* releases to keep around for rollback after a successful
  # deploy. The current release is always retained on top of these.
  @retain_prior 3

  @default_github_api "https://api.github.com"

  @default_timeout_s 60

  @switches [version: :string, timeout: :integer, json: :boolean, force: :boolean]

  @doc "Entry point for `arb server deploy` (release-based path)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_deploy(argv)
    end
  end

  defp do_deploy(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      [{flag, _} | _] = invalid
      Output.die("unknown option #{flag} for `arb server deploy`")
    end

    mode = if opts[:json], do: :json, else: :text
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000
    force = opts[:force] || false

    # A worker must never bounce the orchestrating server, and an in-flight
    # deploy must not abandon active workers. Same guards as `arb restart`.
    # Resolve the repo first so a misconfiguration fails fast, before we reach
    # for the (HTTP-backed) active-worker check.
    Restart.guard_acolyte_session!()
    repo = release_repo()
    Restart.guard_active_workers!(force)

    release = fetch_release(repo, opts[:version])
    tag = release_tag(release)

    releases_dir = releases_dir()
    target_dir = Path.join(releases_dir, tag)
    current_link = current_link()

    # Idempotency: if `current` already points at this tag, there's nothing to
    # do unless the operator forces a redeploy.
    if not force and current_target_basename(current_link) == tag do
      emit_already_current(mode, tag)
    else
      {tarball_url, sha_url} = release_assets(release, tag)

      log("Downloading #{asset_name(tag)} from #{repo}@#{tag}…")
      tarball = download_binary(tarball_url)
      expected_sha = parse_sha256(download_binary(sha_url))

      verify_sha256!(tarball, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      unpack!(tarball, target_dir)
      run_migrations!(target_dir)

      # Refresh the PATH in arbiter.env from the deploying shell before
      # restarting the service. The EnvironmentFile= directive loads this file,
      # so any stale or test-corrupted PATH= line here would break every worker
      # spawn after the restart. Writing now ensures the service always boots
      # with the same PATH the operator used to invoke this deploy.
      refresh_env_path()
      preflight_claude_path()

      prior_target = current_target(current_link)
      atomic_symlink_swap!(current_link, target_dir)
      log("Swapped #{current_link} -> #{target_dir}")

      case Restart.perform(restart_root(current_link), timeout_ms) do
        {:ok, actions, was_running} ->
          pruned = prune_old_releases(releases_dir, target_dir, prior_target)
          emit_deployed(mode, tag, prior_basename(prior_target), actions, was_running, pruned)

        {:timeout, _actions, _was_running} ->
          rolled_back = auto_rollback(current_link, prior_target, timeout_ms)
          emit_rollback(mode, tag, rolled_back, timeout_ms)
      end
    end
  end

  # ---- release resolution -------------------------------------------------

  # `owner/repo` to pull releases from. Required — there's no safe default for
  # "where does this server's code come from".
  defp release_repo do
    case System.get_env("ARB_RELEASE_REPO") do
      slug when is_binary(slug) and slug != "" ->
        slug

      _ ->
        Output.die(
          "ARB_RELEASE_REPO is not set",
          "Set it to the GitHub `owner/repo` that publishes Arbiter releases, " <>
            "e.g. ARB_RELEASE_REPO=acme/arbiter."
        )
    end
  end

  # Fetch the release metadata for `latest` or a specific tag.
  defp fetch_release(repo, nil), do: github_get!(repo, "releases/latest", "latest")
  defp fetch_release(repo, tag), do: github_get!(repo, "releases/tags/#{tag}", tag)

  defp github_get!(repo, path, what) do
    url = github_api() <> "/repos/" <> repo <> "/" <> path

    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        receive_timeout: 30_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: 404}} ->
        Output.die(
          "no #{what} release found in #{repo}",
          "Check `--version` matches a published tag, or publish a release first."
        )

      {:ok, %Req.Response{status: status}} ->
        Output.die("GitHub Releases API returned HTTP #{status} for #{url}")

      {:error, reason} ->
        Output.die(
          "could not reach the GitHub Releases API",
          "Requesting #{url} failed: #{inspect(reason)}"
        )
    end
  end

  defp release_tag(%{"tag_name" => tag}) when is_binary(tag) and tag != "", do: tag

  defp release_tag(_),
    do: Output.die("release metadata has no tag_name", "The Releases API response was malformed.")

  # Locate the linux tarball asset and its `.sha256` sidecar in the release's
  # asset list, returning their download URLs.
  defp release_assets(%{"assets" => assets}, tag) when is_list(assets) do
    name = asset_name(tag)
    sha_name = name <> ".sha256"

    tarball_url = asset_url(assets, name)
    sha_url = asset_url(assets, sha_name)

    cond do
      is_nil(tarball_url) ->
        Output.die(
          "release #{tag} has no asset named #{name}",
          "The release workflow should publish it; re-run the build if it's missing."
        )

      is_nil(sha_url) ->
        Output.die(
          "release #{tag} has no checksum asset named #{sha_name}",
          "Refusing to deploy without a checksum to verify the download against."
        )

      true ->
        {tarball_url, sha_url}
    end
  end

  defp release_assets(_, tag),
    do: Output.die("release #{tag} has no assets")

  defp asset_url(assets, name) do
    Enum.find_value(assets, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  defp asset_name(tag), do: "arbiter-#{tag}-linux.tar.gz"

  # ---- download + verify --------------------------------------------------

  defp download_binary(url) do
    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        # Asset bodies are opaque bytes (a gzip tarball / a text checksum); never
        # let Req try to JSON-decode or transparently gunzip them.
        decode_body: false,
        raw: true,
        receive_timeout: 120_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status}} ->
        Output.die("download failed: HTTP #{status} for #{url}")

      {:error, reason} ->
        Output.die("download failed for #{url}", inspect(reason))
    end
  end

  # A `sha256sum` line is `<hex>  <filename>`; take the leading hex token.
  defp parse_sha256(contents) do
    contents
    |> to_string()
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      hex when is_binary(hex) and hex != "" -> String.downcase(hex)
      _ -> Output.die("could not parse the published sha256 checksum")
    end
  end

  defp verify_sha256!(tarball, expected) do
    actual = :crypto.hash(:sha256, tarball) |> Base.encode16(case: :lower)

    unless actual == expected do
      Output.die(
        "sha256 checksum mismatch — refusing to deploy",
        "expected #{expected}\n             got #{actual}\n" <>
          "The download is corrupt or tampered with. Aborting before touching the symlink."
      )
    end
  end

  # ---- unpack -------------------------------------------------------------

  # Unpack the OTP-release tarball into `target_dir`. The tarball has a single
  # top-level `arbiter/` directory (it's built with `tar -C _build/prod/rel
  # arbiter`); we strip that leading component so `bin/arbiter` lands directly
  # under `target_dir`.
  defp unpack!(tarball, target_dir) do
    # Start from a clean directory so a retried deploy of the same tag can't
    # mix old and new files.
    _ = File.rm_rf(target_dir)
    File.mkdir_p!(target_dir)

    staging = target_dir <> ".unpack"
    _ = File.rm_rf(staging)
    File.mkdir_p!(staging)

    log("Unpacking release to #{target_dir}…")

    case :erl_tar.extract({:binary, tarball}, [:compressed, {:cwd, to_charlist(staging)}]) do
      :ok ->
        promote_unpacked!(staging, target_dir)
        _ = File.rm_rf(staging)
        :ok

      {:error, reason} ->
        _ = File.rm_rf(staging)
        _ = File.rm_rf(target_dir)
        Output.die("failed to unpack the release tarball", inspect(reason))
    end
  end

  # Move the contents of the tarball's top-level dir up into `target_dir`. If
  # the archive has the expected single `arbiter/` root we strip it; otherwise
  # we keep whatever layout it shipped (defensive — still produces a usable
  # release dir for non-standard archives).
  defp promote_unpacked!(staging, target_dir) do
    case File.ls!(staging) do
      [single] ->
        single_path = Path.join(staging, single)

        if File.dir?(single_path) do
          Enum.each(File.ls!(single_path), fn entry ->
            File.rename!(Path.join(single_path, entry), Path.join(target_dir, entry))
          end)
        else
          File.rename!(single_path, Path.join(target_dir, single))
        end

      entries ->
        Enum.each(entries, fn entry ->
          File.rename!(Path.join(staging, entry), Path.join(target_dir, entry))
        end)
    end
  end

  # ---- migrate ------------------------------------------------------------

  defp run_migrations!(target_dir) do
    bin = Path.join(target_dir, "bin/arbiter")
    log("Running migrations (bin/arbiter eval Arbiter.Release.migrate)…")

    case Start.run_cmd(bin, ["eval", "Arbiter.Release.migrate"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        # Migration failed *before* we swapped the symlink — the live server is
        # untouched, so just abort.
        _ = File.rm_rf(target_dir)

        Output.die(
          "database migration failed (exit #{code})",
          "The live release was not changed. Output:\n" <> String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      _ = File.rm_rf(target_dir)

      Output.die(
        "could not run #{Path.join(target_dir, "bin/arbiter")}: #{inspect(e.original)}",
        "Is the unpacked release executable on this platform?"
      )
  end

  # ---- symlink swap -------------------------------------------------------

  # Atomically point `link_path` at `target` by creating a temp symlink and
  # rename(2)-ing it over the existing one. rename is atomic on POSIX, so a
  # concurrent reader sees either the old target or the new one, never nothing.
  defp atomic_symlink_swap!(link_path, target) do
    File.mkdir_p!(Path.dirname(link_path))
    tmp = link_path <> ".new"
    _ = File.rm(tmp)

    with :ok <- File.ln_s(target, tmp),
         :ok <- File.rename(tmp, link_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Output.die("failed to swap the current-release symlink", inspect(reason))
    end
  end

  # The release dir `link_path` currently resolves to (absolute), or nil if the
  # link is absent (first-ever deploy).
  defp current_target(link_path) do
    case File.read_link(link_path) do
      {:ok, target} -> Path.expand(target, Path.dirname(link_path))
      _ -> nil
    end
  end

  defp current_target_basename(link_path) do
    case current_target(link_path) do
      nil -> nil
      target -> Path.basename(target)
    end
  end

  defp prior_basename(nil), do: nil
  defp prior_basename(path), do: Path.basename(path)

  # ---- rollback -----------------------------------------------------------

  # Re-point `current` at the prior release and restart. Returns the prior tag
  # on success, or nil when there was no prior release to fall back to (e.g. a
  # failed first-ever deploy — nothing to roll back to).
  defp auto_rollback(_current_link, nil, _timeout_ms), do: nil

  defp auto_rollback(current_link, prior_target, timeout_ms) do
    log("Health check failed — rolling back to #{Path.basename(prior_target)}…")
    atomic_symlink_swap!(current_link, prior_target)
    # Best-effort: bring the prior release back up. We report whatever doctor
    # says afterwards rather than gating the rollback on a fresh green wait.
    _ = Restart.perform(restart_root(current_link), timeout_ms)
    Path.basename(prior_target)
  end

  # ---- prune --------------------------------------------------------------

  # Keep the current release plus the @retain_prior most-recent other releases
  # (by mtime); delete the rest. Returns the list of pruned tags.
  defp prune_old_releases(releases_dir, current_target, prior_target) do
    keep_always =
      [current_target, prior_target]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    all =
      releases_dir
      |> list_release_dirs()
      |> Enum.sort_by(&dir_mtime/1, :desc)

    # The newest @retain_prior dirs that aren't already force-kept, plus the
    # always-keep set, form the retained set.
    extra_keep =
      all
      |> Enum.reject(&MapSet.member?(keep_always, &1))
      |> Enum.take(@retain_prior)
      |> MapSet.new()

    keep = MapSet.union(keep_always, extra_keep)

    pruned =
      all
      |> Enum.reject(&MapSet.member?(keep, &1))

    Enum.each(pruned, fn tag ->
      _ = File.rm_rf(Path.join(releases_dir, tag))
    end)

    if pruned != [], do: log("Pruned old release(s): #{Enum.join(pruned, ", ")}")
    pruned
  end

  defp list_release_dirs(releases_dir) do
    case File.ls(releases_dir) do
      {:ok, entries} ->
        Enum.filter(entries, fn e ->
          File.dir?(Path.join(releases_dir, e)) and not String.ends_with?(e, ".unpack")
        end)

      _ ->
        []
    end
  end

  defp dir_mtime(tag) do
    case File.stat(Path.join(releases_dir(), tag), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  # ---- env refresh --------------------------------------------------------

  # Write the deploying shell's PATH into arbiter.env so the restarted service
  # inherits a working PATH (one that finds claude, arb, mise shims, etc.).
  # Idempotent: uses the same read/merge/write logic as `arb install service`.
  defp refresh_env_path do
    home = data_home()
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

  # ---- paths / config -----------------------------------------------------

  defp data_home do
    case System.get_env("ARB_DATA_HOME") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(System.user_home!(), ".arbiter")
    end
  end

  defp releases_dir, do: Path.join(data_home(), "releases")
  defp current_link, do: Path.join(data_home(), "current")

  # `Restart.perform/2` only uses `root` for its non-systemd `mix phx.server`
  # fallback; in the release world the systemd unit owns the process, so the
  # current symlink dir is a fine, always-present value to pass.
  defp restart_root(current_link), do: current_link

  defp github_api do
    case System.get_env("ARB_GITHUB_API") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_github_api
    end
  end

  defp github_headers do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | base]

      _ ->
        base
    end
  end

  # Test hook mirroring `ArbiterCli.Client`: a test stuffs Req options (e.g.
  # `plug: {Req.Test, Stub}`) into the process dict to redirect HTTP.
  defp test_opts, do: Process.get(:bd2_req_options, [])

  # Progress chatter, routed through the same seam as `arb start`/`arb restart`
  # so it stays quiet under test and on `--json`.
  defp log(msg), do: Start.log_text(msg)

  # ---- output -------------------------------------------------------------

  defp emit_already_current(:json, tag) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        deployed: false,
        already_current: true,
        rolled_back: false,
        ok: true
      })
    )
  end

  defp emit_already_current(:text, tag) do
    IO.puts("Already on release #{tag} — nothing to deploy.")
    IO.puts("(Pass --force to redeploy the same version, or --version to pick another.)")
  end

  defp emit_deployed(:json, tag, prior, actions, was_running, pruned) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        previous_version: prior,
        deployed: true,
        already_current: false,
        rolled_back: false,
        was_running: was_running,
        actions: action_payload(actions),
        pruned: pruned,
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: Doctor.green?()
      })
    )
  end

  defp emit_deployed(:text, tag, prior, _actions, _was_running, pruned) do
    IO.puts("")
    IO.puts("Deployed release #{tag}" <> if(prior, do: " (was #{prior})", else: ""))

    if pruned != [] do
      IO.puts("Pruned #{length(pruned)} old release(s): #{Enum.join(pruned, ", ")}")
    end

    IO.puts("")
    IO.puts("Arbiter restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  defp emit_rollback(:json, tag, rolled_back, timeout_ms) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        deployed: false,
        rolled_back: rolled_back != nil,
        rolled_back_to: rolled_back,
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: false,
        timed_out_after_s: div(timeout_ms, 1000)
      })
    )

    Output.halt(1)
  end

  defp emit_rollback(:text, tag, rolled_back, timeout_ms) do
    IO.puts("")
    IO.puts("Release #{tag} did not come back green within #{div(timeout_ms, 1000)}s.")

    if rolled_back do
      IO.puts("Rolled back to #{rolled_back} and restarted.")
    else
      IO.puts("No prior release to roll back to — the stack is down.")
    end

    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for startup output.")
    Output.halt(1)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end
end
