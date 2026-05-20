defmodule GtElixir.Trackers.Jira.Config do
  @moduledoc """
  Reads the Jira tracker configuration from the active workspace.

  ## Resolution order

    1. Process dict (`put_active/1`) — set by request lifecycles or tests.
    2. `Application.get_env(:gt_elixir, :jira_default_config)` — a static
       fallback for tools that don't carry a workspace (e.g. a CLI escript
       or a Mix task seeded from env vars).
    3. Neither → `{:error, %Error{kind: :config_missing}}`.

  ## Shape

      %{
        "host" => "leotechnologies.atlassian.net",
        "project_key" => "VR",
        "credentials_ref" => "env:JIRA_TOKEN",
        "email" => "ryan.born@leotechnologies.com",
        # optional:
        "status_map" => %{
          "open" => "To Do",
          "in_progress" => "In Progress",
          "closed" => "Approved and merged"
        },
        "field_ids" => %{
          "title" => "summary",
          "description" => "description",
          "qa_notes" => "customfield_10300",
          "deployment_notes" => "customfield_10400",
          "assignee" => "assignee"
        }
      }

  `credentials_ref` is a small DSL: `"env:NAME"` looks up `System.get_env/1`.
  Other prefixes (e.g. `"file:..."`) could be added later; today only `env:`
  is supported. A bare string (no prefix) is treated as a literal token, but
  this should be avoided outside of tests.
  """

  alias GtElixir.Beads.Workspace
  alias GtElixir.Trackers.Jira.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_status_map %{
    open: "To Do",
    in_progress: "In Progress",
    closed: "Done"
  }

  @default_field_ids %{
    title: "summary",
    description: "description",
    assignee: "assignee"
  }

  @type config :: %{
          host: String.t(),
          project_key: String.t(),
          email: String.t() | nil,
          token: String.t(),
          status_map: %{atom() => String.t()},
          field_ids: %{atom() => String.t()}
        }

  @doc """
  Set the active Jira workspace config for the current process. Accepts a
  `Workspace` (reads its `config["tracker"]["config"]`), a raw tracker-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config}) do
    tracker_config = get_in(config || %{}, ["tracker", "config"]) || %{}
    Process.put(@pdict_key, tracker_config)
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
  Resolve the active Jira config into a fully-populated struct (with the
  token already looked up from env). Returns `{:ok, config}` or
  `{:error, %Error{kind: :config_missing}}`.
  """
  @spec resolve() :: {:ok, config} | {:error, Error.t()}
  def resolve do
    raw =
      Process.get(@pdict_key) ||
        Application.get_env(:gt_elixir, :jira_default_config) ||
        %{}

    with {:ok, host} <- fetch_string(raw, "host"),
         {:ok, project_key} <- fetch_string(raw, "project_key"),
         {:ok, token} <- fetch_token(raw) do
      {:ok,
       %{
         host: host,
         project_key: project_key,
         email: stringy(Map.get(raw, "email")),
         token: token,
         status_map: status_map(raw),
         field_ids: field_ids(raw)
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

  @doc "Returns the active project_key, or nil if none."
  @spec active_project_key() :: String.t() | nil
  def active_project_key do
    case Process.get(@pdict_key) || Application.get_env(:gt_elixir, :jira_default_config) do
      %{"project_key" => key} when is_binary(key) -> key
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
             "Jira config missing #{inspect(key)}. Set workspace.config[\"tracker\"][\"config\"][#{inspect(key)}] or :gt_elixir, :jira_default_config in Application env.",
           raw: nil
         }}
    end
  end

  defp fetch_token(raw) do
    case Map.get(raw, "credentials_ref") do
      "env:" <> name ->
        case System.get_env(name) do
          v when is_binary(v) and v != "" ->
            {:ok, v}

          _ ->
            {:error,
             %Error{
               kind: :config_missing,
               status: nil,
               message: "Jira credentials env var #{inspect(name)} is unset",
               raw: nil
             }}
        end

      v when is_binary(v) and v != "" ->
        # literal token — discouraged outside of tests
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message: "Jira config missing \"credentials_ref\"",
           raw: nil
         }}
    end
  end

  defp status_map(raw) do
    user = Map.get(raw, "status_map") || %{}

    Enum.into(@default_status_map, %{}, fn {atom_key, default} ->
      {atom_key, Map.get(user, Atom.to_string(atom_key), default)}
    end)
  end

  defp field_ids(raw) do
    user = Map.get(raw, "field_ids") || %{}

    base =
      Enum.into(@default_field_ids, %{}, fn {atom_key, default} ->
        {atom_key, Map.get(user, Atom.to_string(atom_key), default)}
      end)

    # Allow workspace to define extra fields beyond the defaults.
    extras =
      for {k, v} <- user, is_binary(k), is_binary(v), into: %{} do
        {String.to_atom(k), v}
      end

    Map.merge(base, extras)
  end

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v), do: v
  defp stringy(_), do: nil
end
