defmodule Arbiter.Agents.Codex.Config do
  @moduledoc """
  Reads the Codex agent's configuration from the active workspace.

  Mirrors `Arbiter.Agents.Gemini.Config`. The active workspace config is
  seeded by `Arbiter.Agents.prepare/1` and stored in the process dictionary.

  Codex normally authenticates through the operator's ChatGPT login under
  `$CODEX_HOME` (`~/.codex/auth.json`), so an API key is *optional*: when a
  workspace supplies one (or `OPENAI_API_KEY` is in the ambient env) the
  adapter exports it, otherwise it lets the CLI use the ChatGPT auth already on
  disk.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Tasks.Workspace

  @pdict_key {__MODULE__, :active_workspace_config}
  @rotation_key {__MODULE__, :api_key_rotation_index}

  @type t :: %{
          model: String.t() | nil,
          credentials_ref: String.t() | nil,
          api_keys: [String.t()],
          raw: map()
        }

  # Default tier → concrete Codex model. Overridable per-workspace via
  # `agent.config["tier_models"]` (string keys). The values are model ids the
  # `codex --model` flag accepts. Codex's coding-tuned model is the same across
  # tiers today (only the reasoning `effort` differs); the map exists so a
  # workspace can pin cheaper/pricier ids without an adapter change.
  @default_tier_models %{
    "economy" => "gpt-5-codex-mini",
    "standard" => "gpt-5-codex",
    "premium" => "gpt-5-codex"
  }

  @doc "Set the active Codex agent config for the current process."
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

  def put_active(%Workspace{config: config} = workspace, role)
      when role in [:agent, :review_agent] do
    raw = get_in(config || %{}, [Atom.to_string(role), "config"]) || %{}
    Process.put(@pdict_key, CredentialsRef.embed_secrets(raw, Workspace.secrets_map(workspace)))
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

  @doc "Resolve the active Codex config."
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
  Resolve the active API key, rotating through `api_keys` (if present) on each
  call. Falls back to a `credentials_ref` then the ambient `OPENAI_API_KEY`.
  Returns `nil` when nothing is configured — the adapter then relies on the
  ChatGPT auth in `$CODEX_HOME`.
  """
  @spec resolve_api_key() :: String.t() | nil
  def resolve_api_key do
    {:ok, cfg} = resolve()

    case cfg.api_keys do
      [] ->
        case resolve_ref(cfg.credentials_ref, cfg.raw) do
          nil -> ambient_api_key()
          key -> key
        end

      keys ->
        keys
        |> rotate_pick()
        |> resolve_ref(cfg.raw)
    end
  end

  @doc "Return the active model name as a string, or `nil` if unset."
  @spec active_model() :: String.t() | nil
  def active_model do
    {:ok, cfg} = resolve()
    cfg.model
  end

  @doc """
  Resolve an abstract `model_tier` (`"economy"` | `"standard"` | `"premium"`)
  to a concrete Codex model name. Returns `nil` for an unknown / nil tier — the
  adapter falls back to the CLI default. Workspace config can override the
  mapping under `agent.config["tier_models"]`.
  """
  @spec model_for_tier(String.t() | nil) :: String.t() | nil
  def model_for_tier(nil), do: nil
  def model_for_tier(""), do: nil

  def model_for_tier(tier) when is_binary(tier) do
    {:ok, cfg} = resolve()
    overrides = stringy_map(Map.get(cfg.raw, "tier_models"))

    case Map.get(overrides, tier) || Map.get(@default_tier_models, tier) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  def model_for_tier(_), do: nil

  @doc "Built-in default tier → model map (testing / introspection)."
  def default_tier_models, do: @default_tier_models

  # ---- Internals --------------------------------------------------------

  defp ambient_api_key, do: System.get_env("OPENAI_API_KEY")

  defp resolve_ref(nil, _raw), do: nil
  defp resolve_ref("", _raw), do: nil

  defp resolve_ref(ref, raw) do
    case CredentialsRef.resolve(ref, raw) do
      {:ok, value} -> value
      _ -> nil
    end
  end

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

  defp stringy_map(nil), do: %{}

  defp stringy_map(m) when is_map(m) do
    for {k, v} <- m, is_binary(k), is_binary(v) and v != "", into: %{}, do: {k, v}
  end

  defp stringy_map(_), do: %{}
end
