defmodule Arbiter.Mergers.Github.RepoResolver do
  @moduledoc """
  Derives a GitHub `{owner, repo}` pair from a local repo's `origin` remote.

  Used by `Arbiter.Mergers.Github` when the workspace's `merge.config` does
  not pin a single `repo` — a multi-repo workspace whose repos live in
  *different* repos (e.g. the `leotech` workspace, whose four repos are four
  separate `leo-technologies-llc/*` repos) resolves the target repo per-repo
  from each repo's git remote.

  Parses both common remote forms:

    * SSH:    `git@github.com:owner/repo.git` (or without the `.git` suffix)
    * HTTPS:  `https://github.com/owner/repo.git` (or without the `.git` suffix)

  The host is not constrained — Enterprise GitHub hosts (e.g.
  `git@github.example.com:owner/repo.git`) parse the same way. The merger's
  `base_url` is the constraint on which host is actually contacted.
  """

  alias Arbiter.Mergers.Github.Error

  @doc """
  Run `git -C <repo_path> remote get-url origin` and parse `{owner, repo}`.

  Returns `{:error, %Error{kind: :config_missing}}` when the remote is
  missing, malformed, or git fails (e.g. `repo_path` is not a git checkout).
  """
  @spec from_remote(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def from_remote(repo_path) when is_binary(repo_path) and repo_path != "" do
    case System.cmd("git", ["-C", repo_path, "remote", "get-url", "origin"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse(String.trim(output))
      {output, _} -> {:error, remote_error("git remote get-url origin failed", output)}
    end
  rescue
    e in ErlangError ->
      {:error, remote_error("git not available on PATH", Exception.message(e))}
  end

  def from_remote(_),
    do: {:error, remote_error("repo_path missing for per-repo repo derivation", nil)}

  @doc """
  Parse an `origin` URL into `{owner, repo}`. Public for tests.
  """
  @spec parse(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def parse(url) when is_binary(url) do
    cond do
      # SSH: git@host:owner/repo(.git)
      match = Regex.run(~r{^[^@\s]+@[^:\s]+:([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}, url) ->
        [_, owner, repo] = match
        {:ok, {owner, repo}}

      # HTTPS / HTTP / git protocol: scheme://host[:port]/owner/repo(.git)
      match = Regex.run(~r{^[a-z]+://[^/\s]+/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}, url) ->
        [_, owner, repo] = match
        {:ok, {owner, repo}}

      true ->
        {:error, remote_error("could not parse origin URL #{inspect(url)}", url)}
    end
  end

  defp remote_error(msg, raw) do
    %Error{kind: :config_missing, status: nil, message: msg, raw: raw}
  end
end
