defmodule Arbiter.Trackers.Shortcut.Config do
  @moduledoc """
  Reads the Shortcut tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :shortcut_default_config)` — a static
       fallback for tools that don't carry a workspace (e.g. a CLI escript or
       a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  ## Shape

      %{
        "credentials_ref" => "env:SHORTCUT_TOKEN",
        # optional:
        "workflow_id" => 123,
        "status_map" => %{
          "open" => "Unstarted",
          "in_progress" => "In Progress",
          "closed" => "Done"
        }
      }

  Unlike Jira, Shortcut needs no host or project key — every story lives under
  the same `api.app.shortcut.com` workspace, scoped by the API token alone.

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  A bare string (no prefix) is treated as a literal token, but this should be
  avoided outside of tests.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Shortcut.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_status_map %{
    open: "Unstarted",
    in_progress: "In Progress",
    closed: "Done"
  }

  # Default difficulty bucket thresholds. Active only when the workspace sets
  # `difficulty.buckets` in the tracker config.
  @default_difficulty_buckets [{1, 0}, {3, 1}, {5, 2}, {8, 3}]

  @type config :: %{
          token: String.t(),
          workflow_id: integer() | nil,
          status_map: %{atom() => String.t()},
          estimate_buckets: [{non_neg_integer(), 0..4}] | nil
        }

  @doc """
  Set the active Shortcut workspace config for the current process. Accepts a
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

  @doc """
  Merge a per-repo tracker config override over the current process's active
  config. Looks up `config["tracker"]["config"]["repos"][repo]` and, if present,
  merges it over the config seeded by `put_active/1` — so a workspace whose
  repos bind to different Shortcut projects targets the right one. No-op when
  `repo` is nil/blank or the workspace declares no override for it. See
  `Arbiter.Trackers.ConfigOverride`.
  """
  @spec override_repo(Workspace.t() | nil, String.t() | nil) :: :ok
  def override_repo(workspace, repo),
    do: Arbiter.Trackers.ConfigOverride.apply(@pdict_key, workspace, repo)

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    :ok
  end

  @doc """
  Resolve the active Shortcut config into a fully-populated struct (with the
  token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :shortcut_default_config) ||
        %{}

    with {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         token: token,
         workflow_id: workflow_id(raw),
         status_map: status_map(raw),
         estimate_buckets: estimate_buckets(raw)
       }}
    end
  end

  @doc "Same as resolve/0 but raises on missing config (for callers that prefer fail-fast)."
  @spec resolve!() :: config | no_return
  def resolve! do
    case resolve() do
      {:ok, cfg} ->
        cfg

      {:error, %Error{message: msg}} ->
        raise ArgumentError, msg
    end
  end

  # ---- Internals ----------------------------------------------------------

  # Resolve the token via the shared credentials_ref DSL (env: / secret: /
  # literal), mapping its tagged failures onto Shortcut's config_missing error.
  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("Shortcut credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error, config_missing("Shortcut secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error,
         config_missing(
           "Shortcut config missing \"credentials_ref\". Set " <>
             "workspace.config[\"tracker\"][\"config\"][\"credentials_ref\"] or " <>
             ":arbiter, :shortcut_default_config in Application env."
         )}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp workflow_id(raw) do
    case Map.get(raw, "workflow_id") do
      id when is_integer(id) -> id
      id when is_binary(id) -> with {n, ""} <- Integer.parse(id), do: n, else: (_ -> nil)
      _ -> nil
    end
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    Enum.into(@default_status_map, %{}, fn {atom_key, default} ->
      {atom_key, Map.get(user, Atom.to_string(atom_key), default)}
    end)
  end

  # estimate_buckets: [{max_pts, difficulty}] sorted ascending, or nil (off).
  # Enabled by setting `difficulty.buckets` in the workspace tracker config.
  # Shortcut stories have a numeric `estimate` field; without configured buckets
  # the feature is off (nil) — default.
  defp estimate_buckets(raw) do
    case get_in(raw, ["difficulty", "buckets"]) do
      buckets when is_list(buckets) and length(buckets) > 0 ->
        parse_buckets(buckets) || @default_difficulty_buckets

      _ ->
        nil
    end
  end

  defp parse_buckets(buckets) do
    parsed =
      Enum.flat_map(buckets, fn
        [max, diff]
        when (is_integer(max) or is_float(max)) and is_integer(diff) and diff >= 0 and diff <= 4 ->
          [{round(max), diff}]

        _ ->
          []
      end)

    case Enum.sort_by(parsed, fn {max, _} -> max end) do
      [] -> nil
      sorted -> sorted
    end
  end
end
