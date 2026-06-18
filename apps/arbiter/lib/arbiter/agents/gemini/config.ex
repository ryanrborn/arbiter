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

  # Default tier → concrete Gemini model. Used when only a tier is known
  # (no thinking level). Overridable per-workspace via
  # `agent.config["tier_models"]` (string keys).
  @default_tier_models %{
    "economy" => "gemini-2.5-flash-lite",
    "standard" => "gemini-2.5-flash",
    "premium" => "gemini-2.5-pro"
  }

  # Combined tier+thinking → agy model name. `agy` encodes both in the
  # model string (e.g. "Gemini 3.1 Pro (High)"), so there is no separate
  # thinking flag — the two knobs resolve together. Overridable per-workspace
  # via `agent.config["combined_models"]` using the same "tier/thinking" keys.
  #
  # Pro has no Medium tier; premium/medium rounds down to Pro (Low).
  # xhigh and max both cap at High (highest available).
  @default_combined_models %{
    "economy/none" => "Gemini 3.5 Flash (Low)",
    "economy/low" => "Gemini 3.5 Flash (Low)",
    "economy/medium" => "Gemini 3.5 Flash (Medium)",
    "economy/high" => "Gemini 3.5 Flash (High)",
    "economy/xhigh" => "Gemini 3.5 Flash (High)",
    "economy/max" => "Gemini 3.5 Flash (High)",
    "standard/none" => "Gemini 3.5 Flash (Low)",
    "standard/low" => "Gemini 3.5 Flash (Low)",
    "standard/medium" => "Gemini 3.5 Flash (Medium)",
    "standard/high" => "Gemini 3.5 Flash (High)",
    "standard/xhigh" => "Gemini 3.5 Flash (High)",
    "standard/max" => "Gemini 3.5 Flash (High)",
    "premium/none" => "Gemini 3.1 Pro (Low)",
    "premium/low" => "Gemini 3.1 Pro (Low)",
    "premium/medium" => "Gemini 3.1 Pro (Low)",
    "premium/high" => "Gemini 3.1 Pro (High)",
    "premium/xhigh" => "Gemini 3.1 Pro (High)",
    "premium/max" => "Gemini 3.1 Pro (High)"
  }

  # Default thinking → CLI argv tokens. `agy` has no dedicated thinking
  # flag (it's encoded in the model name), so all levels are empty here.
  # Workspaces that pin a different CLI fork can override per-level argv
  # via `agent.config["thinking_argv"]`.
  @default_thinking_argv %{
    "none" => [],
    "low" => [],
    "medium" => [],
    "high" => [],
    "xhigh" => [],
    "max" => []
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

  @doc """
  Resolve an abstract `model_tier` (`"economy"` | `"standard"` |
  `"premium"`) to a concrete Gemini model name. Returns `nil` for an
  unknown / nil tier — the adapter falls back to its CLI default.

  Workspace config can override the mapping under
  `agent.config["tier_models"]`. Missing keys fall back to the built-in
  default (`#{inspect(@default_tier_models)}`).
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

  @doc """
  Resolve a combined `model_tier` + `thinking` pair to a concrete model
  name for the `agy` CLI, which encodes both in the model string (e.g.
  `"Gemini 3.1 Pro (High)"`). Returns `nil` when the combination is
  unknown — callers should fall back to `model_for_tier/1`.

  Workspace config can override the mapping under
  `agent.config["combined_models"]` using `"tier/thinking"` string keys.
  """
  @spec model_for_tier_and_thinking(String.t() | nil, String.t() | nil) :: String.t() | nil
  def model_for_tier_and_thinking(nil, _), do: nil
  def model_for_tier_and_thinking(_, nil), do: nil
  def model_for_tier_and_thinking("", _), do: nil
  def model_for_tier_and_thinking(_, ""), do: nil

  def model_for_tier_and_thinking(tier, thinking) when is_binary(tier) and is_binary(thinking) do
    {:ok, cfg} = resolve()
    overrides = stringy_map(Map.get(cfg.raw, "combined_models"))
    key = "#{tier}/#{thinking}"

    case Map.get(overrides, key) || Map.get(@default_combined_models, key) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  def model_for_tier_and_thinking(_, _), do: nil

  @doc """
  Resolve an abstract `thinking` level to a list of CLI argv tokens to
  append to the spawn command. The default mapping is empty for all
  levels — `agy` has no dedicated thinking flag (it is encoded in the
  model name via `model_for_tier_and_thinking/2`). Workspaces that pin a
  different CLI fork can override per-level argv via
  `agent.config["thinking_argv"]`.
  """
  @spec thinking_argv(String.t() | nil) :: [String.t()]
  def thinking_argv(nil), do: []
  def thinking_argv(""), do: []
  def thinking_argv("none"), do: []

  def thinking_argv(level) when is_binary(level) do
    {:ok, cfg} = resolve()
    overrides = list_map(Map.get(cfg.raw, "thinking_argv"))

    case Map.get(overrides, level) || Map.get(@default_thinking_argv, level) do
      argv when is_list(argv) -> argv
      _ -> []
    end
  end

  def thinking_argv(_), do: []

  @doc """
  Resolve an abstract `thinking` level to a list of `{name, value}` env
  pairs. The default surfaces the level itself via
  `GEMINI_THINKING_LEVEL` so an external wrapper / shim can consume it
  without a CLI flag. `none` / `nil` / unknown → `[]`.
  """
  @spec thinking_env(String.t() | nil) :: [{String.t(), String.t()}]
  def thinking_env(nil), do: []
  def thinking_env(""), do: []
  def thinking_env("none"), do: []

  def thinking_env(level) when level in ["low", "medium", "high", "xhigh", "max"] do
    [{"GEMINI_THINKING_LEVEL", level}]
  end

  def thinking_env(_), do: []

  @doc "Built-in default tier → model map (testing / introspection)."
  def default_tier_models, do: @default_tier_models

  @doc "Built-in default combined tier/thinking → model map (testing / introspection)."
  def default_combined_models, do: @default_combined_models

  @doc "Built-in default thinking → argv map (testing / introspection)."
  def default_thinking_argv, do: @default_thinking_argv

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

  defp stringy_map(nil), do: %{}

  defp stringy_map(m) when is_map(m) do
    for {k, v} <- m, is_binary(k), is_binary(v) and v != "", into: %{}, do: {k, v}
  end

  defp stringy_map(_), do: %{}

  defp list_map(nil), do: %{}

  defp list_map(m) when is_map(m) do
    for {k, v} <- m,
        is_binary(k),
        is_list(v),
        Enum.all?(v, &is_binary/1),
        into: %{},
        do: {k, v}
  end

  defp list_map(_), do: %{}
end
