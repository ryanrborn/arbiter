defmodule Arbiter.Mergers.Github.Config do
  @moduledoc """
  Reads the GitHub merger configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :github_merger_default_config)` — a
       static fallback for tools that don't carry a workspace (e.g. a CLI
       escript or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  Mirrors `Arbiter.Trackers.Jira.Config` — the merger adapter is
  workspace-scoped, so it resolves owner / repo / credentials the same way
  the Jira tracker resolves host / project_key / credentials.

  ## Shape

  Read from `workspace.config["merge"]["config"]` (the adapter is selected by
  `workspace.config["merge"]["strategy"] == "github"`):

      %{
        "owner" => "myorg",
        "repo" => "myrepo",
        "credentials_ref" => "env:GITHUB_TOKEN",
        # optional:
        "default_target_branch" => "main",
        "default_reviewers" => [],
        "merge_method" => "squash"
      }

  Both `owner` and `repo` are optional: a workspace can omit both and let the
  adapter derive them per-rig from the rig's `origin` remote via
  `Arbiter.Mergers.Github.RepoResolver` (the leotech workspace does this for
  all four of its `leo-technologies-llc/*` rigs). A single-repo workspace may
  still pin `repo` here for the legacy bare-ref shape, but this is deprecated —
  repo is a rig-level concern.

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  A bare string (no prefix) is treated as a literal token, but this should be
  avoided outside of tests.

  `merge_method` is one of `"squash"`, `"merge"`, `"rebase"`; it defaults to
  `"squash"` and resolves to the matching atom. An unrecognised value falls
  back to `:squash`.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Mergers.Github.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_base_url "https://api.github.com"
  @default_target_branch "main"
  @default_merge_method :squash

  @type config :: %{
          base_url: String.t(),
          owner: String.t() | nil,
          repo: String.t() | nil,
          token: String.t(),
          default_target_branch: String.t(),
          default_reviewers: [String.t()],
          merge_method: :squash | :merge | :rebase
        }

  @doc """
  Set the active GitHub merger config for the current process. Accepts a
  `Workspace` (reads its `config["merge"]["config"]`), a raw merger-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config} = workspace) do
    merger_config = get_in(config || %{}, ["merge", "config"]) || %{}

    Process.put(
      @pdict_key,
      CredentialsRef.embed_secrets(merger_config, Workspace.secrets_map(workspace))
    )

    :ok
  end

  def put_active(%{} = merger_config) do
    Process.put(@pdict_key, merger_config)
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Override the `owner` and `repo` in the current process's active GitHub config.

  Used by `Arbiter.Workflows.PRPatrol` to seed the per-patrol repo before
  calling `list_open/0`. Multi-repo workspaces omit `repo` from their merge
  config (the per-rig repo is derived from the rig's git remote at open time),
  so each PRPatrol instance calls this with its own `"owner/repo"` slug to make
  `list_open/0` resolve the correct REST endpoint.

  Merges into the existing pdict config so credentials and other settings set
  by `put_active/1` are preserved. No-op when the slug can't be parsed.
  """
  @spec override_repo(String.t()) :: :ok
  def override_repo(repo_slug) when is_binary(repo_slug) do
    case String.split(repo_slug, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" ->
        raw = Process.get(@pdict_key) || %{}
        Process.put(@pdict_key, Map.merge(raw, %{"owner" => owner, "repo" => repo}))
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Resolve the active GitHub merger config into a fully-populated struct (with
  the token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :github_merger_default_config) ||
        %{}

    with {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         base_url: stringy(Map.get(raw, "base_url")) || @default_base_url,
         owner: optional_string(raw, "owner"),
         repo: optional_string(raw, "repo"),
         token: token,
         default_target_branch:
           stringy(Map.get(raw, "default_target_branch")) || @default_target_branch,
         default_reviewers: reviewers(raw),
         merge_method: merge_method(raw)
       }}
    end
  end

  @doc "Same as resolve/0 but raises on missing config (for callers that prefer fail-fast)."
  @spec resolve!() :: config | no_return
  def resolve! do
    case resolve() do
      {:ok, cfg} -> cfg
      {:error, %Error{message: msg}} -> raise ArgumentError, msg
    end
  end

  @doc """
  Returns the active `"owner/repo"` slug, or nil if none is configured. Useful
  for building links and parsing refs without a full resolve.
  """
  @spec active_repo_slug() :: String.t() | nil
  def active_repo_slug do
    raw = Process.get(@pdict_key) || Application.get_env(:arbiter, :github_merger_default_config)

    case raw do
      %{"owner" => owner, "repo" => repo} when is_binary(owner) and is_binary(repo) ->
        "#{owner}/#{repo}"

      _ ->
        nil
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp optional_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto the merger's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("GitHub merger credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error,
         config_missing("GitHub merger secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error, config_missing("GitHub merger config missing \"credentials_ref\"")}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp reviewers(raw) do
    case Map.get(raw, "default_reviewers") do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp merge_method(raw) do
    case Map.get(raw, "merge_method") do
      "squash" -> :squash
      "merge" -> :merge
      "rebase" -> :rebase
      _ -> @default_merge_method
    end
  end

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v), do: v
  defp stringy(_), do: nil
end
