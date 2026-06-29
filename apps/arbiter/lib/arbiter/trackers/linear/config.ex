defmodule Arbiter.Trackers.Linear.Config do
  @moduledoc """
  Reads the Linear tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:arbiter, :linear_tracker_default_config)` — a
       static fallback for tools that don't carry a workspace.
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  ## Shape

      %{
        "credentials_ref" => "env:LINEAR_API_KEY",
        # optional:
        "team_id" => "abc123-team-uuid",
        "org_url_key" => "mycompany",
        "base_url" => "https://api.linear.app/graphql",
        "status_map" => %{
          "open" => "Todo",
          "in_progress" => "In Progress",
          "closed" => "Done",
          "pr_opened" => "In Review",
          "merged" => "Done"
        }
      }

  ## `credentials_ref`

  The Linear API key or OAuth token. Uses the shared DSL: `"env:NAME"` looks
  up `System.get_env/1`; `"secret:KEY"` looks up the workspace's encrypted
  secrets; a bare string is treated as a literal token. Pass the raw API key
  without any prefix — the adapter sends it as `Authorization: <token>`.

  ## `team_id`

  The UUID of the Linear team. Required for `create/1` and improves
  `list_transitions/1` (scopes states to a single team). When absent, the
  adapter fetches the first team from the organization for create/list
  operations, which may be incorrect in multi-team workspaces.

  ## `org_url_key`

  The organization's URL slug (e.g. `"mycompany"` in
  `https://linear.app/mycompany/issue/ENG-123`). Used by `link_for/1` to
  build human-clickable URLs. When absent, `link_for/1` returns
  `https://linear.app/issue/{ref}`.

  ## `status_map`

  Maps task-vocabulary status atoms to Linear workflow state *names*. When a
  status name is absent or `nil`, the adapter falls back to Linear's built-in
  state `type` field:

    * `:open` / `:pr_opened` / `:approved_unmerged` → type `"unstarted"` or
      `"backlog"` (first match among the team's states)
    * `:in_progress` → type `"started"`
    * `:closed` / `:merged` → type `"completed"`

  A workspace-specific `status_map` is recommended if the team uses custom
  state names (e.g. `"Backlog"` vs `"Todo"` for open).
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Linear.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_base_url "https://api.linear.app/graphql"

  # Default difficulty bucket thresholds (same as Jira). Active only when the
  # workspace sets `difficulty.buckets` in the tracker config.
  @default_difficulty_buckets [{1, 0}, {3, 1}, {5, 2}, {8, 3}]

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          team_id: String.t() | nil,
          org_url_key: String.t() | nil,
          status_map: %{atom() => String.t() | nil},
          estimate_buckets: [{non_neg_integer(), 0..4}] | nil
        }

  @doc """
  Set the active Linear tracker config for the current process. Accepts a
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
  Resolve the active Linear tracker config into a fully-populated struct (with
  the token already looked up). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:arbiter, :linear_tracker_default_config) ||
        %{}

    with {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         base_url: stringy(Map.get(raw, "base_url")) || @default_base_url,
         token: token,
         team_id: stringy(Map.get(raw, "team_id")),
         org_url_key: stringy(Map.get(raw, "org_url_key")),
         status_map: status_map(raw),
         estimate_buckets: estimate_buckets(raw)
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

  defp fetch_token(raw) do
    case CredentialsRef.resolve(Map.get(raw, "credentials_ref"), raw) do
      {:ok, token} ->
        {:ok, token}

      {:env_unset, name} ->
        {:error, config_missing("Linear credentials env var #{inspect(name)} is unset")}

      {:secret_not_found, key} ->
        {:error, config_missing("Linear secret #{inspect(key)} is not set on the workspace")}

      :missing ->
        {:error,
         config_missing(
           "Linear tracker config missing \"credentials_ref\". Set " <>
             "workspace.config[\"tracker\"][\"config\"][\"credentials_ref\"] or " <>
             ":arbiter, :linear_tracker_default_config in Application env."
         )}
    end
  end

  defp config_missing(message) do
    %Error{kind: :config_missing, status: nil, message: message, raw: nil}
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    Enum.into(
      [:open, :in_progress, :closed, :pr_opened, :approved_unmerged, :merged],
      %{},
      fn atom_key ->
        {atom_key, stringy(Map.get(user, Atom.to_string(atom_key)))}
      end
    )
  end

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v) and v != "", do: v
  defp stringy(_), do: nil

  # estimate_buckets: [{max_pts, difficulty}] sorted ascending, or nil (off).
  # Enabled by setting `difficulty.buckets` in the workspace tracker config.
  # When `difficulty` is absent the feature is off (nil) — default.
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
