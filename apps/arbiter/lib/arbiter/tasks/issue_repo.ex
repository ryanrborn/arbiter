defmodule Arbiter.Tasks.IssueRepo do
  @moduledoc """
  The one repo resolver every issue-creation path runs through (bd-9dwbvt).

  `repo` used to be optional on an issue and was resolved late, at dispatch
  time, from the workspace's sole repo or its `default_repo` (bd-5pctey). That
  left ~64% of issues with a null `repo`: per-repo reporting had nothing to
  group by, and a multi-repo workspace only discovered the ambiguity when a
  dispatch failed with `{:ambiguous_repo, _}`, long after the filing session
  that could have answered it was gone.

  Every issue now resolves its repo at *creation* time instead, in this order:

    1. An explicit repo, canonicalized onto the configured `repo_paths` key it
       matches (see `Arbiter.Tasks.RepoConfig.find_entry/2` — an explicit
       `verus_server` or `leotech/verus-server` both land on a configured
       `verus-server`).
    2. The workspace's only configured repo.
    3. The workspace config's `default_repo`, when it names a configured repo.
    4. Otherwise `{:error, {:repo_required, configured_keys}}` — the caller
       must name one of the listed keys.

  An explicit repo that matches *no* configured key is rejected outright with
  `{:error, {:repo_not_configured, repo, configured_keys}}`: a typo'd or stale
  assignment must not be persisted only to fail later as
  `{:repo_not_found, _}` at dispatch.

  ## The unconfigured-workspace escape hatch

  When a workspace (plus the install-wide `:repo_paths` application env)
  configures **no repos at all**, resolution returns `{:ok, nil}` and an
  explicit repo is passed through unvalidated. There is no set of keys to
  auto-select from, to default to, or to validate against — the error in (4)
  would name an empty list, and a workspace whose `repo_paths` hasn't been
  filled in yet would be unable to file even the issue that asks for it to be
  filled in. This is the same treatment the backfill
  (`Arbiter.Tasks.RepoBackfill`) gives such a workspace: leave it null, report
  it, change nothing else.
  """

  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @type resolution ::
          {:ok, String.t() | nil}
          | {:error, {:repo_required, [String.t()]}}
          | {:error, {:repo_not_configured, String.t(), [String.t()]}}

  @doc """
  Resolve the repo an issue in `workspace_id` should carry, given the
  (possibly nil/blank) `explicit` repo the caller asked for.

  See the module doc for the ordering and the unconfigured-workspace case.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: resolution()
  def resolve(workspace_id, explicit) do
    config = workspace_config(workspace_id)
    repo_maps = repo_maps(config)
    configured = configured_keys(repo_maps)

    case blank_to_nil(explicit) do
      nil -> resolve_implicit(config, configured)
      repo -> resolve_explicit(repo_maps, configured, repo)
    end
  end

  @doc """
  The configured `repo_paths` key `repo` matches in `workspace_id`, or `nil`
  when it matches none (or when the workspace configures no repos).

  For callers that hold a repo name from somewhere else — PRPatrol's patrol
  slug, ExternalReview's PR repo — and want to seed an issue's repo with it
  only if it is actually one of this install's repos, rather than risk a
  `{:repo_not_configured, _, _}` rejection on a name that never resolved.
  """
  @spec configured_key(String.t() | nil, String.t() | nil) :: String.t() | nil
  def configured_key(workspace_id, repo) do
    with repo when is_binary(repo) <- blank_to_nil(repo),
         maps <- workspace_id |> workspace_config() |> repo_maps() do
      canonical_key(maps, repo)
    else
      _ -> nil
    end
  end

  @doc """
  Every repo key configured for `workspace_id` — the workspace's own
  `repo_paths` plus the install-wide `:repo_paths` application env, deduped
  and sorted. Entries with no usable path are dropped.
  """
  @spec configured_repos(String.t() | nil) :: [String.t()]
  def configured_repos(workspace_id) do
    workspace_id |> workspace_config() |> repo_maps() |> configured_keys()
  end

  @doc """
  The workspace config's `default_repo`, when it is set AND names one of the
  workspace's configured repos. `nil` otherwise — a dangling default must not
  be handed out as if it resolved.
  """
  @spec default_repo(String.t() | nil) :: String.t() | nil
  def default_repo(workspace_id) do
    config = workspace_config(workspace_id)
    usable_default(config, config |> repo_maps() |> configured_keys())
  end

  @doc """
  Human-readable rendering of a `resolve/2` error, used verbatim as the
  validation message on the `:repo` field.
  """
  @spec describe_error({:repo_required, [String.t()]} | {:repo_not_configured, String.t(), [String.t()]}) ::
          String.t()
  def describe_error({:repo_required, repos}) do
    "repo is required: this workspace configures more than one repo and has no " <>
      "`default_repo`. Pass one of: #{keys(repos)} (or set `default_repo` in the " <>
      "workspace config)."
  end

  def describe_error({:repo_not_configured, repo, repos}) do
    "#{inspect(repo)} is not one of this workspace's configured repos. " <>
      "Expected one of: #{keys(repos)}."
  end

  # ---- internals -----------------------------------------------------------

  defp resolve_implicit(config, configured) do
    case configured do
      [] -> {:ok, nil}
      [sole] -> {:ok, sole}
      repos -> implicit_default(config, repos)
    end
  end

  defp implicit_default(config, repos) do
    case usable_default(config, repos) do
      nil -> {:error, {:repo_required, repos}}
      default -> {:ok, default}
    end
  end

  defp resolve_explicit(_repo_maps, [], repo), do: {:ok, repo}

  defp resolve_explicit(repo_maps, configured, repo) do
    case canonical_key(repo_maps, repo) do
      nil -> {:error, {:repo_not_configured, repo, configured}}
      key -> {:ok, key}
    end
  end

  # `RepoConfig.find_entry/2` does the loose matching (exact, then
  # separator/case-normalized, then `<owner>/<name>` suffix). It returns the
  # *entry*, so map back to the key it came from — the issue must persist the
  # key dispatch will look up, not the caller's spelling of it.
  defp canonical_key(repo_maps, repo) do
    Enum.find_value(repo_maps, &key_from_entry(&1, repo)) || slug_key(repo_maps, repo)
  end

  defp key_from_entry(map, repo) do
    case RepoConfig.find_entry(map, repo) do
      nil ->
        nil

      entry ->
        Enum.find_value(map, fn {k, v} ->
          if v == entry and RepoConfig.repo_path_from_config(v) != nil, do: k
        end)
    end
  end

  # Reverse slug resolution, the same miss-path fallback
  # `Arbiter.Worker.Dispatch` does for `{:repo_not_found, _}` (bd-49ajyt):
  # `repo_paths` is keyed by bare repo name ("client") while PRPatrol /
  # ReviewPatrol / a PR URL only have the forge slug ("leotech/verus-client"),
  # and neither spelling contains the other. Match by reading each configured
  # checkout's `origin` remote.
  #
  # Only runs when every cheap pass above missed AND the repo is slug-shaped,
  # so an ordinary repo-name create never pays the git cost.
  defp slug_key(repo_maps, repo) do
    if String.contains?(repo, "/") do
      target = RepoConfig.normalize_slug(repo)

      Enum.find_value(repo_maps, fn map ->
        Enum.find_value(map, fn {k, v} ->
          with path when is_binary(path) <- RepoConfig.repo_path_from_config(v),
               {:ok, {owner, name}} <- RepoResolver.from_remote(path),
               true <- RepoConfig.normalize_slug("#{owner}/#{name}") == target do
            k
          else
            _ -> nil
          end
        end)
      end)
    end
  end

  defp usable_default(config, repos) do
    case config do
      %{"default_repo" => default} when is_binary(default) and default != "" ->
        if default in repos, do: default

      _ ->
        nil
    end
  end

  defp repo_maps(config) do
    ws_map =
      case config do
        %{"repo_paths" => rp} when is_map(rp) -> rp
        _ -> %{}
      end

    [ws_map, Application.get_env(:arbiter, :repo_paths, %{})]
    |> Enum.filter(&is_map/1)
  end

  defp configured_keys(repo_maps) do
    repo_maps
    |> Enum.flat_map(fn map ->
      Enum.flat_map(map, fn {k, v} ->
        if is_binary(k) and RepoConfig.repo_path_from_config(v) != nil, do: [k], else: []
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp workspace_config(nil), do: %{}

  defp workspace_config(workspace_id) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, %Workspace{config: %{} = config}} -> config
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp workspace_config(_), do: %{}

  defp blank_to_nil(repo) when is_binary(repo) do
    case String.trim(repo) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp keys([]), do: "(none configured)"
  defp keys(repos), do: Enum.map_join(repos, ", ", &inspect/1)
end
