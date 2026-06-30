defmodule ArbiterCli.Cmd.SelfUpdate do
  @moduledoc """
  `arb self-update [--version vX.Y.Z] [--json] [--force]`
  — refresh the local `arb` CLI escript from a **GitHub Release**.

  Downloads the `arb` escript asset published by `.github/workflows/release.yml`,
  verifies its SHA-256 checksum, backs up the existing binary, and atomically
  swaps in the new one.

  This is the production CLI-update path: the machine no longer needs a source
  checkout or a Mix/Elixir toolchain to stay current. It mirrors
  `arb server deploy` — download a released artifact, verify, swap — so CLI
  and server self-maintain the same way.

  ## What it does

    1. **Resolve the target release.** Query the GitHub Releases API for
       `latest` (or the tag named by `--version`). The `owner/repo` comes from
       `ARB_RELEASE_REPO`; a `GITHUB_TOKEN`, if set, authenticates the request.
    2. **No-op if already current.** Compare the running escript's version
       against the release tag. Skips the download unless `--force` is passed.
    3. **Download the asset + checksum.** Fetch the `arb` escript asset and its
       `arb.sha256` sidecar from the release.
    4. **Verify sha256.** Recompute the download's SHA-256 and compare to the
       published checksum. A mismatch aborts before anything touches disk state.
    5. **Atomic swap.** Back up the existing binary to `<install_path>.bak`,
       write the new binary to a temp file, `chmod +x`, then rename it over the
       existing path (rename(2) is atomic on POSIX).

  ## Configuration

    * `ARB_RELEASE_REPO` — `owner/repo` to pull releases from (required).
    * `GITHUB_TOKEN` — optional; authenticates the Releases API request.
    * `ARB_INSTALL_BIN` — install path (default `~/.local/bin/arb`).
    * `ARB_GITHUB_API` — Releases API base (default `https://api.github.com`).

  ## Exit codes

    * `0` — the CLI was updated (or was already on the target version).
    * `1` — a precondition failed (missing config, API/download error, checksum
      mismatch, write failure).
  """

  alias ArbiterCli.Output

  @default_github_api "https://api.github.com"
  @switches [version: :string, json: :boolean, force: :boolean]

  @doc "Entry point for `arb self-update` (and its `arb upgrade` alias)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_self_update(argv)
    end
  end

  defp do_self_update(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      [{flag, _} | _] = invalid
      Output.die("unknown option #{flag} for `arb self-update`")
    end

    mode = if opts[:json], do: :json, else: :text
    force = opts[:force] || false

    repo = release_repo()
    release = fetch_release(repo, opts[:version])
    tag = release_tag(release)

    # Strip the leading `v` from the tag before comparing with the app version
    # (the app version is stored without the prefix, e.g. "0.1.10").
    tag_version = String.trim_leading(tag, "v")
    current_version = ArbiterCli.Version.app_version()

    if not force and tag_version == current_version do
      emit_already_current(mode, tag)
    else
      {arb_url, sha_url} = cli_assets(release, tag)

      log("Downloading arb escript from #{repo}@#{tag}…")
      arb_bytes = download_binary(arb_url)
      expected_sha = parse_sha256(download_binary(sha_url))

      verify_sha256!(arb_bytes, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      install_path = install_path()
      atomic_swap!(install_path, arb_bytes)

      emit_updated(mode, tag, current_version)
    end
  end

  # ---- release resolution --------------------------------------------------

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

  # Locate the `arb` escript asset and its `arb.sha256` sidecar.
  defp cli_assets(%{"assets" => assets}, tag) when is_list(assets) do
    arb_url = asset_url(assets, "arb")
    sha_url = asset_url(assets, "arb.sha256")

    cond do
      is_nil(arb_url) ->
        Output.die(
          "release #{tag} has no asset named `arb`",
          "The release workflow should publish it; re-run the build if it's missing."
        )

      is_nil(sha_url) ->
        Output.die(
          "release #{tag} has no checksum asset named `arb.sha256`",
          "Refusing to update without a checksum to verify the download against."
        )

      true ->
        {arb_url, sha_url}
    end
  end

  defp cli_assets(_, tag), do: Output.die("release #{tag} has no assets")

  defp asset_url(assets, name) do
    Enum.find_value(assets, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  # ---- download + verify ---------------------------------------------------

  defp download_binary(url) do
    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
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

  defp verify_sha256!(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    unless actual == expected do
      Output.die(
        "sha256 checksum mismatch — refusing to update",
        "expected #{expected}\n             got #{actual}\n" <>
          "The download is corrupt or tampered with. Aborting before touching the binary."
      )
    end
  end

  # ---- atomic swap ---------------------------------------------------------

  defp atomic_swap!(install_path, bytes) do
    install_dir = Path.dirname(install_path)

    case File.mkdir_p(install_dir) do
      :ok -> :ok
      {:error, reason} -> Output.die("could not create #{install_dir}: #{inspect(reason)}")
    end

    # Back up the existing binary so the user can roll back manually.
    if File.exists?(install_path) do
      bak = install_path <> ".bak"

      case File.copy(install_path, bak) do
        {:ok, _} -> log("Backed up existing binary to #{bak}")
        {:error, reason} -> Output.die("could not back up #{install_path}: #{inspect(reason)}")
      end
    end

    # Write to a temp file alongside the target, then rename(2) over it.
    tmp = install_path <> ".new"
    _ = File.rm(tmp)

    with :ok <- File.write(tmp, bytes),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, install_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Output.die("failed to install arb to #{install_path}", inspect(reason))
    end
  end

  # ---- paths / config ------------------------------------------------------

  defp install_path do
    case System.get_env("ARB_INSTALL_BIN") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(System.user_home!(), ".local/bin/arb")
    end
  end

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

  defp test_opts, do: Process.get(:bd2_req_options, [])

  defp log(msg) do
    unless Process.get(:bd2_req_options) do
      IO.puts(msg)
    end
  end

  # ---- output --------------------------------------------------------------

  defp emit_already_current(:json, tag) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        updated: false,
        already_current: true,
        ok: true
      })
    )
  end

  defp emit_already_current(:text, tag) do
    IO.puts("Already on #{tag} — nothing to update.")
    IO.puts("(Pass --force to reinstall the same version, or --version to pick another.)")
  end

  defp emit_updated(:json, tag, prior_version) do
    install = install_path()

    IO.puts(
      Jason.encode!(%{
        version: tag,
        previous_version: prior_version,
        updated: true,
        already_current: false,
        install_path: install,
        ok: true
      })
    )
  end

  defp emit_updated(:text, tag, prior_version) do
    install = install_path()
    IO.puts("")
    IO.puts("Updated arb to #{tag}" <> if(prior_version, do: " (was #{prior_version})", else: ""))
    IO.puts("Installed at #{install}")
    IO.puts("")
    IO.puts("Run `arb version` to confirm the new version is active.")
  end
end
