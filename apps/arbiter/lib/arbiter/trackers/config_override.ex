defmodule Arbiter.Trackers.ConfigOverride do
  @moduledoc """
  Shared per-repo override for tracker adapter configs.

  Tracker adapters seed their per-process config from
  `workspace.config["tracker"]["config"]` via each `Config.put_active/1`. A
  multi-repo workspace whose repos map to *different* tracker bindings (e.g.
  two GitHub repos filing issues to different `owner/repo`, or two projects on
  the same Jira host) adds a `"repos"` map, keyed by the same repo name used in
  `config["repo_paths"]`:

      %{
        "host" => "acme.atlassian.net",
        "project_key" => "CORE",             # default / single-repo binding
        "credentials_ref" => "env:JIRA_TOKEN",
        "repos" => %{
          "device" => %{"project_key" => "DEV"}
        }
      }

  After `put_active/1` has seeded the workspace-wide config, `apply/3` merges
  the repo's override over it — so the resolved binding targets the right
  project for the repo actually in play instead of the workspace-wide default.
  Unset keys in the override fall back to the workspace binding.

  This mirrors `Arbiter.Mergers.Gitlab.Config.override_repo/2` for the merger
  side; each tracker `Config` exposes a one-line `override_repo/2` that
  delegates here with its own process-dictionary key, and
  `Arbiter.Trackers.prepare_with_repo/3` dispatches to the right adapter.

  A no-op when `repo` is nil/blank or the workspace declares no override for
  it — the `put_active/1` config is left untouched, so workspaces without a
  `"repos"` map (the common case) behave exactly as before.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace

  @doc """
  Merge `workspace.config["tracker"]["config"]["repos"][repo]` over the config
  already seeded in the process dictionary under `pdict_key`.

  Secrets in the override (`credentials_ref` DSL) are embedded with the same
  `Workspace.secrets_map/1` the adapter's `put_active/1` uses, so a repo
  override can carry its own credential reference.
  """
  @spec apply(term(), Workspace.t() | nil, String.t() | nil) :: :ok
  def apply(_pdict_key, _workspace, repo) when repo in [nil, ""], do: :ok
  def apply(_pdict_key, nil, _repo), do: :ok

  def apply(pdict_key, %Workspace{config: config} = workspace, repo) when is_binary(repo) do
    case get_in(config || %{}, ["tracker", "config", "repos", repo]) do
      %{} = override when map_size(override) > 0 ->
        active = Process.get(pdict_key) || %{}
        embedded = CredentialsRef.embed_secrets(override, Workspace.secrets_map(workspace))
        Process.put(pdict_key, Map.merge(active, embedded))
        :ok

      _ ->
        :ok
    end
  end
end
