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

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Shortcut.Error

  @pdict_key {__MODULE__, :active_workspace_config}

  @default_status_map %{
    open: "Unstarted",
    in_progress: "In Progress",
    closed: "Done"
  }

  @type config :: %{
          token: String.t(),
          workflow_id: integer() | nil,
          status_map: %{atom() => String.t()}
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
         status_map: status_map(raw)
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
               message: "Shortcut credentials env var #{inspect(name)} is unset",
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
           message:
             "Shortcut config missing \"credentials_ref\". Set " <>
               "workspace.config[\"tracker\"][\"config\"][\"credentials_ref\"] or " <>
               ":arbiter, :shortcut_default_config in Application env.",
           raw: nil
         }}
    end
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
end
