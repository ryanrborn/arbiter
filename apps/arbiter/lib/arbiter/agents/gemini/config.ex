defmodule Arbiter.Agents.Gemini.Config do
  @moduledoc """
  Reads the Gemini agent's configuration from the active workspace.

  Mirrors `Arbiter.Agents.Claude.Config`. The active workspace config is
  seeded by `Arbiter.Agents.prepare/1` and stored in the process dictionary.
  """

  alias Arbiter.Beads.Workspace

  @pdict_key {__MODULE__, :active_workspace_config}
  @rotation_key {__MODULE__, :api_key_rotation_index}

  @type t :: %{
          model: String.t() | nil,
          credentials_ref: String.t() | nil,
          api_keys: [String.t()],
          raw: map()
        }

  @doc """
  Set the active Gemini agent config for the current process.
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(thing), do: put_active(thing, :agent)

  @doc """
  Set the active config for either the worker `:agent` or the reviewer
  `:review_agent` role.
  """
  @spec put_active(Workspace.t() | map() | nil, :agent | :review_agent) :: :ok
  def put_active(nil, _role) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_active(%Workspace{config: config}, role) when role in [:agent, :review_agent] do
    raw = get_in(config || %{}, [Atom.to_string(role), "config"]) || %{}
    Process.put(@pdict_key, raw)
    :ok
  end

  def put_active(%{} = raw, _role) do
    Process.put(@pdict_key, raw)
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    Process.delete(@rotation_key)
    :ok
  end

  @doc """
  Resolve the active Gemini config.
  """
  @spec resolve() :: {:ok, t()}
  def resolve do
    raw = Process.get(@pdict_key) || %{}

    {:ok,
     %{
       model: stringy(Map.get(raw, "model")),
       credentials_ref: stringy(Map.get(raw, "credentials_ref")),
       api_keys: list_of_strings(Map.get(raw, "api_keys")),
       raw: raw
     }}
  end

  @doc """
  Resolve the active API key, rotating through `api_keys` (if present) on
  each call. Defaults to GEMINI_API_KEY then GOOGLE_GENAI_API_KEY.
  """
  @spec resolve_api_key() :: String.t() | nil
  def resolve_api_key do
    {:ok, cfg} = resolve()

    case cfg.api_keys do
      [] ->
        case resolve_ref(cfg.credentials_ref) do
          nil -> ambient_api_key()
          key -> key
        end

      keys ->
        keys
        |> rotate_pick()
        |> resolve_ref()
    end
  end

  @doc """
  Return the active model name as a string, or `nil` if unset.
  """
  @spec active_model() :: String.t() | nil
  def active_model do
    {:ok, cfg} = resolve()
    cfg.model
  end

  # ---- Internals --------------------------------------------------------

  defp ambient_api_key do
    System.get_env("GEMINI_API_KEY") || System.get_env("GOOGLE_GENAI_API_KEY")
  end

  defp resolve_ref(nil), do: nil
  defp resolve_ref(""), do: nil

  defp resolve_ref("env:" <> name) do
    case System.get_env(name) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp resolve_ref(literal) when is_binary(literal), do: literal

  defp rotate_pick(keys) do
    idx = Process.get(@rotation_key, 0)
    key = Enum.at(keys, rem(idx, length(keys)))
    Process.put(@rotation_key, idx + 1)
    key
  end

  defp list_of_strings(list) when is_list(list),
    do: Enum.filter(list, fn v -> is_binary(v) and v != "" end)

  defp list_of_strings(_), do: []

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v) and v != "", do: v
  defp stringy(_), do: nil
end
