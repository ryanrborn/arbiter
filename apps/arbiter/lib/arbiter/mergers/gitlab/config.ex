defmodule Arbiter.Mergers.Gitlab.Config do
  @moduledoc """
  Reads the GitLab merger configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :gitlab_default_config)` — a static
       fallback for tools that don't carry a workspace (e.g. a CLI escript
       or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  This mirrors `Arbiter.Trackers.Jira.Config`. The merger abstraction
  discriminates on `config["merge"]["strategy"]` (see
  `Arbiter.Tasks.Workspace.merger_strategy/1`); the adapter-specific shape
  lives under `config["merge"]["config"]`, parallel to how a tracker nests
  its config under `config["tracker"]["config"]`.

  ## Shape

      %{
        "host" => "gitlab.com",
        "project_id" => 12345,
        "credentials_ref" => "env:GITLAB_TOKEN",
        # optional:
        "default_target_branch" => "main",
        "default_reviewers" => []
      }

  `project_id` is GitLab's numeric project ID (or a URL-encoded
  `"group/project"` path) — passed through verbatim into the API path, so
  either an integer or a binary is accepted.

  `credentials_ref` is the same small DSL the tracker adapters use:
  `"env:NAME"` looks up `System.get_env/1`; a bare string is treated as a
  literal token (discouraged outside of tests).
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Mergers.Gitlab.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_target_branch "main"

  @type config :: %{
          host: String.t(),
          project_id: String.t(),
          token: String.t(),
          default_target_branch: String.t(),
          default_reviewers: [term()]
        }

  @doc """
  Set the active GitLab merger config for the current process. Accepts a
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
    merge_config = get_in(config || %{}, ["merge", "config"]) || %{}

    Process.put(
      @pdict_key,
      CredentialsRef.embed_secrets(merge_config, Workspace.secrets_map(workspace))
    )

    :ok
  end

  def put_active(%{} = merge_config) do
    Process.put(@pdict_key, merge_config)
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Resolve the active GitLab config into a fully-populated struct (with the
  token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :gitlab_default_config) ||
        %{}

    with {:ok, host} <- fetch_string(raw, "host"),
         {:ok, project_id} <- fetch_project_id(raw),
         {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         host: host,
         project_id: project_id,
         token: token,
         default_target_branch:
           stringy(Map.get(raw, "default_target_branch")) || @default_target_branch,
         default_reviewers: List.wrap(Map.get(raw, "default_reviewers"))
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

  # ---- Internals ----------------------------------------------------------

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message:
             "GitLab config missing #{inspect(key)}. Set workspace.config[\"merge\"][\"config\"][#{inspect(key)}] or :arbiter, :gitlab_default_config in Application env.",
           raw: nil
         }}
    end
  end

  # project_id may be an integer (numeric ID) or a binary ("group/project").
  defp fetch_project_id(raw) do
    case Map.get(raw, "project_id") do
      v when is_integer(v) -> {:ok, Integer.to_string(v)}
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> fetch_string(raw, "project_id")
    end
  end

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto GitLab's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("GitLab credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error, config_missing("GitLab secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error, config_missing("GitLab config missing \"credentials_ref\"")}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v) and v != "", do: v
  defp stringy(_), do: nil
end
