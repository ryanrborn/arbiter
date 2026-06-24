defmodule Arbiter.Trackers.GitHub.Config do
  @moduledoc """
  Reads the GitHub Issues tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :github_tracker_default_config)` — a
       static fallback for tools that don't carry a workspace (e.g. a CLI
       escript or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  Mirrors `Arbiter.Trackers.Jira.Config` and `Arbiter.Mergers.Github.Config` —
  the tracker adapter is workspace-scoped, so it resolves owner / repo /
  credentials the same way.

  ## Shape

  Read from `workspace.config["tracker"]["config"]` (the adapter is selected by
  `workspace.config["tracker"]["type"] == "github"`):

      %{
        "owner" => "ryanrborn",
        "repo" => "arbiter",
        "credentials_ref" => "env:GITHUB_TOKEN",
        # optional:
        "base_url" => "https://api.github.com",
        "status_map" => %{
          "open" => %{"state" => "open"},
          "in_progress" => %{"state" => "open", "label" => "in progress"},
          "closed" => %{"state" => "closed"}
        }
      }

  ## `status_map`

  GitHub Issues have only two native states — `"open"` and `"closed"` — so the
  task-vocabulary `:in_progress` is expressed as an *open* issue carrying a
  label. Each task status maps to a `%{state: ..., label: ...}` pair:

    * `state` is `"open"` or `"closed"` (anything else falls back to the
      default for that status).
    * `label` is an optional GitHub label name (`nil` for none). On
      `transition/2` the adapter swaps the managed status labels — it adds the
      target's label and removes the other statuses' labels, leaving unrelated
      labels untouched.

  A workspace may write each entry as the full map above, or as a bare state
  string (`"closed" => "closed"`), which is read as `%{state: "closed",
  label: nil}`. An *absent* status inherits the full default; a *present* entry
  is taken exactly as written (an absent label means "no label", not the
  default). Defaults: open → open/no-label, in_progress → open/"in progress",
  closed → closed/no-label.

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  A bare string (no prefix) is treated as a literal token, but this should be
  avoided outside of tests.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.GitHub.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_base_url "https://api.github.com"

  @default_status_map %{
    open: %{state: "open", label: nil},
    in_progress: %{state: "open", label: "in progress"},
    closed: %{state: "closed", label: nil}
  }

  @valid_states ~w(open closed)

  @type status_entry :: %{state: String.t(), label: String.t() | nil}

  @type config :: %{
          base_url: String.t(),
          owner: String.t(),
          repo: String.t(),
          token: String.t(),
          status_map: %{atom() => status_entry}
        }

  @doc """
  Set the active GitHub tracker config for the current process. Accepts a
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
  Resolve the active GitHub tracker config into a fully-populated struct (with
  the token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :github_tracker_default_config) ||
        %{}

    with {:ok, owner} <- fetch_string(raw, "owner"),
         {:ok, repo} <- fetch_string(raw, "repo"),
         {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         base_url: stringy(Map.get(raw, "base_url")) || @default_base_url,
         owner: owner,
         repo: repo,
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
  Returns the active `"owner/repo"` slug, or nil if none is configured. Useful
  for building links and parsing refs without a full resolve.
  """
  @spec active_repo_slug() :: String.t() | nil
  def active_repo_slug do
    raw = Process.get(@pdict_key) || Application.get_env(:arbiter, :github_tracker_default_config)

    case raw do
      %{"owner" => owner, "repo" => repo} when is_binary(owner) and is_binary(repo) ->
        "#{owner}/#{repo}"

      _ ->
        nil
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
             "GitHub tracker config missing #{inspect(key)}. Set workspace.config[\"tracker\"][\"config\"][#{inspect(key)}] or :arbiter, :github_tracker_default_config in Application env.",
           raw: nil
         }}
    end
  end

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto the tracker's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("GitHub tracker credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error,
         config_missing("GitHub tracker secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error, config_missing("GitHub tracker config missing \"credentials_ref\"")}
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
  # taken exactly as written — only an absent status inherits the default —
  # so an invalid/missing state in a present entry still falls back to the
  # default state, but an absent label means "no label" (not the default).
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

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v), do: v
  defp stringy(_), do: nil
end
