defmodule Arbiter.Trackers.Gitlab.Config do
  @moduledoc """
  Reads the GitLab Issues tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :gitlab_tracker_default_config)` — a
       static fallback for tools that don't carry a workspace (e.g. a CLI
       escript or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  Mirrors `Arbiter.Trackers.GitHub.Config` and `Arbiter.Mergers.Gitlab.Config` —
  the tracker adapter is workspace-scoped, so it resolves host / project /
  credentials the same way. The adapter is selected by
  `workspace.config["tracker"]["type"] == "gitlab"`, and its config nests under
  `workspace.config["tracker"]["config"]`.

  ## Shape

      %{
        "host" => "gitlab.com",
        "project_id" => 12345,                 # numeric ID or "group/project"
        "credentials_ref" => "env:GITLAB_TOKEN",
        # optional:
        "status_map" => %{
          "open" => %{"state" => "opened"},
          "in_progress" => %{"state" => "opened", "label" => "in progress"},
          "closed" => %{"state" => "closed"}
        }
      }

  `project_id` is GitLab's numeric project ID (or a URL-encoded
  `"group/project"` path) — passed through verbatim into the API path, so
  either an integer or a binary is accepted, exactly as the merger config does.

  ## `status_map`

  GitLab Issues have only two native states — `"opened"` and `"closed"` — so
  the task-vocabulary `:in_progress` is expressed as an *open* issue carrying a
  label. Each task status maps to a `%{state: ..., label: ...}` pair:

    * `state` is `"opened"` or `"closed"` (anything else falls back to the
      default for that status).
    * `label` is an optional GitLab label name (`nil` for none). On
      `transition/2` the adapter swaps the managed status labels — it adds the
      target's label and removes the other statuses' labels, leaving unrelated
      labels untouched.

  A workspace may write each entry as the full map above, or as a bare state
  string (`"closed" => "closed"`), read as `%{state: "closed", label: nil}`. An
  *absent* status inherits the full default; a *present* entry is taken exactly
  as written (an absent label means "no label", not the default). Defaults:
  open → opened/no-label, in_progress → opened/"in progress", closed →
  closed/no-label.

  `credentials_ref` is the same small DSL the other adapters use: `"env:NAME"`
  looks up `System.get_env/1`; a bare string is treated as a literal token
  (discouraged outside of tests).
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Gitlab.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_status_map %{
    open: %{state: "opened", label: nil},
    in_progress: %{state: "opened", label: "in progress"},
    closed: %{state: "closed", label: nil}
  }

  @valid_states ~w(opened closed)

  @type status_entry :: %{state: String.t(), label: String.t() | nil}

  @type config :: %{
          host: String.t(),
          project_id: String.t(),
          token: String.t(),
          status_map: %{atom() => status_entry}
        }

  @doc """
  Set the active GitLab tracker config for the current process. Accepts a
  `Workspace` (reads its `config["tracker"]["config"]`), a raw tracker-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config} = workspace) do
    tracker_config = get_in(config || %{}, ["tracker", "config"]) || %{}

    Process.put(
      @pdict_key,
      CredentialsRef.embed_secrets(tracker_config, Workspace.secrets_map(workspace))
    )

    :ok
  end

  def put_active(%{} = tracker_config) do
    Process.put(@pdict_key, tracker_config)
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Resolve the active GitLab tracker config into a fully-populated struct (with
  the token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :gitlab_tracker_default_config) ||
        %{}

    with {:ok, host} <- fetch_string(raw, "host"),
         {:ok, project_id} <- fetch_project_id(raw),
         {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         host: host,
         project_id: project_id,
         token: token,
         status_map: status_map(raw)
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
  Returns the active `project_id` (numeric ID or `"group/project"` path), or
  nil if none is configured. Useful for building links and parsing refs without
  a full resolve.
  """
  @spec active_project_id() :: String.t() | nil
  def active_project_id do
    raw = Process.get(@pdict_key) || Application.get_env(:arbiter, :gitlab_tracker_default_config)

    case raw && Map.get(raw, "project_id") do
      v when is_integer(v) -> Integer.to_string(v)
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  @doc """
  Returns the active host (e.g. `"gitlab.com"`), or nil if none is configured.
  """
  @spec active_host() :: String.t() | nil
  def active_host do
    raw = Process.get(@pdict_key) || Application.get_env(:arbiter, :gitlab_tracker_default_config)

    case raw && Map.get(raw, "host") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
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
             "GitLab tracker config missing #{inspect(key)}. Set workspace.config[\"tracker\"][\"config\"][#{inspect(key)}] or :arbiter, :gitlab_tracker_default_config in Application env.",
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
  # literal), mapping its tagged failures onto the tracker's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("GitLab tracker credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error,
         config_missing("GitLab tracker secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error, config_missing("GitLab tracker config missing \"credentials_ref\"")}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    Enum.into(@default_status_map, %{}, fn {atom_key, default} ->
      {atom_key, status_entry(Map.get(user, Atom.to_string(atom_key)), default)}
    end)
  end

  # A user entry can be a full map (%{"state" => ..., "label" => ...}), a bare
  # state string ("closed"), or absent (use the default). A *present* entry is
  # taken exactly as written — only an absent status inherits the default.
  defp status_entry(nil, default), do: default

  defp status_entry(state, default) when is_binary(state) do
    %{state: valid_state(state, default.state), label: nil}
  end

  defp status_entry(%{} = entry, default) do
    %{
      state: valid_state(Map.get(entry, "state"), default.state),
      label: label(Map.get(entry, "label"))
    }
  end

  defp status_entry(_, default), do: default

  defp valid_state(state, _fallback) when state in @valid_states, do: state
  defp valid_state(_state, fallback), do: fallback

  defp label(v) when is_binary(v) and v != "", do: v
  defp label(_v), do: nil
end
