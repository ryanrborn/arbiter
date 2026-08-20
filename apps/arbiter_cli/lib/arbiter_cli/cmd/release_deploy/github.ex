defmodule ArbiterCli.Cmd.ReleaseDeploy.Github do
  @moduledoc """
  GitHub Releases API access for `arb server deploy`: resolving a release
  (`latest` or a specific tag), locating its tarball + checksum assets, and
  downloading + verifying them.
  """

  alias ArbiterCli.Output

  @default_github_api "https://api.github.com"

  # `owner/repo` to pull releases from. Required — there's no safe default for
  # "where does this server's code come from".
  @spec release_repo() :: String.t()
  def release_repo do
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
  @spec fetch_release(String.t(), String.t() | nil) :: map()
  def fetch_release(repo, nil), do: github_get!(repo, "releases/latest", "latest")
  def fetch_release(repo, tag), do: github_get!(repo, "releases/tags/#{tag}", tag)

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

  @spec release_tag(map()) :: String.t()
  def release_tag(%{"tag_name" => tag}) when is_binary(tag) and tag != "", do: tag

  def release_tag(_),
    do: Output.die("release metadata has no tag_name", "The Releases API response was malformed.")

  # Locate the linux tarball asset and its `.sha256` sidecar in the release's
  # asset list, returning their download URLs.
  @spec release_assets(map(), String.t()) :: {String.t(), String.t()}
  def release_assets(%{"assets" => assets}, tag) when is_list(assets) do
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

  def release_assets(_, tag),
    do: Output.die("release #{tag} has no assets")

  defp asset_url(assets, name) do
    Enum.find_value(assets, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  @spec asset_name(String.t()) :: String.t()
  def asset_name(tag), do: "arbiter-#{tag}-linux.tar.gz"

  @spec download_binary(String.t()) :: binary()
  def download_binary(url) do
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
  @spec parse_sha256(binary()) :: String.t()
  def parse_sha256(contents) do
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

  @spec verify_sha256!(binary(), String.t()) :: :ok
  def verify_sha256!(tarball, expected) do
    actual = :crypto.hash(:sha256, tarball) |> Base.encode16(case: :lower)

    unless actual == expected do
      Output.die(
        "sha256 checksum mismatch — refusing to deploy",
        "expected #{expected}\n             got #{actual}\n" <>
          "The download is corrupt or tampered with. Aborting before touching the symlink."
      )
    end

    :ok
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

  # Test hook mirroring `ArbiterCli.Client`: a test stuffs Req options (e.g.
  # `plug: {Req.Test, Stub}`) into the process dict to redirect HTTP.
  defp test_opts, do: Process.get(:bd2_req_options, [])
end
