defmodule Arbiter.Agents.Gemini.Config do
  @moduledoc """
  Reads the Gemini agent's configuration from the active workspace.

  Mirrors `Arbiter.Agents.Claude.Config`. The active workspace config is
  seeded by `Arbiter.Agents.prepare/1` and stored in the process dictionary.
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

  # Default tier → concrete Gemini model. Overridable per-workspace via
  # `agent.config["tier_models"]` (string keys). The values are short
  # model identifiers the agy / gemini CLI accept via `--model`.
  @default_tier_models %{
    "economy" => "gemini-2.5-flash-lite",
    "standard" => "gemini-2.5-flash",
    "premium" => "gemini-2.5-pro"
  }

  # Default thinking → CLI argv tokens. Gemini's thinking knob varies per
  # CLI fork (agy vs gemini), so the default leaves the argv empty and
  # exposes the level via env var (`GEMINI_THINKING_LEVEL`) — workspaces
  # can override per-level argv with `agent.config["thinking_argv"]` (e.g.
  # `--thinking-budget 8192`) once they pin a CLI surface.
  @default_thinking_argv %{
    "none" => [],
    "low" => [],
    "medium" => [],
    "high" => []
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
  Resolve an abstract `thinking` level to a list of CLI argv tokens to
  append to the spawn command. The default mapping is empty for all
  levels — Gemini's reasoning knob varies per CLI fork; the level is
  surfaced via the `GEMINI_THINKING_LEVEL` env var instead (see
  `thinking_env/1`) and the workspace can opt into CLI argv via
  `agent.config["thinking_argv"]` once a flag is pinned.
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

  def thinking_env(level) when level in ["low", "medium", "high"] do
    [{"GEMINI_THINKING_LEVEL", level}]
  end

  def thinking_env(_), do: []

  @doc "Built-in default tier → model map (testing / introspection)."
  def default_tier_models, do: @default_tier_models

  @doc "Built-in default thinking → argv map (testing / introspection)."
  def default_thinking_argv, do: @default_thinking_argv

  # ---- Internals --------------------------------------------------------

  defp ambient_api_key do
    System.get_env("GEMINI_API_KEY") || System.get_env("GOOGLE_GENAI_API_KEY")
  end

  # Resolve a ref (env: / secret: / literal) against the active config map
  # (which carries the workspace's embedded secrets). A missing credential is
  # not an error for Gemini — it resolves to nil and the caller falls back to
  # the ambient GEMINI_API_KEY / GOOGLE_GENAI_API_KEY.
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
