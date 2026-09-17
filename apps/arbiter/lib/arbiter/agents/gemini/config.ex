defmodule Arbiter.Agents.Gemini.Config do
  @moduledoc """
  Reads the Gemini agent's configuration from the active workspace.

  Mirrors `Arbiter.Agents.Claude.Config`. The active workspace config is
  seeded by `Arbiter.Agents.prepare/1` and stored in the process dictionary.

  In a multi-provider pool the flat `agent.config` keys (`tier_models`,
  `thinking_argv`, …) are shared across every adapter; nest an override under
  the `"gemini"` key (e.g. `agent.config["gemini"]["tier_models"]`) to scope it
  to this adapter alone. See `Arbiter.Agents.ProviderConfig` (applied at
  `put_active/2`) and `Arbiter.Agents.Claude.Config` for the full shape.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Agents.ProviderConfig
  alias Arbiter.Tasks.Workspace

  # Provider name used to scope per-provider overrides in a shared
  # multi-provider `agent.config` (see `Arbiter.Agents.ProviderConfig`).
  @provider "gemini"

  @pdict_key {__MODULE__, :active_workspace_config}
  @rotation_key {__MODULE__, :api_key_rotation_index}

  @type t :: %{
          model: String.t() | nil,
          credentials_ref: String.t() | nil,
          api_keys: [String.t()],
          raw: map()
        }

  # Default tier → concrete Gemini model, for the upstream `gemini` CLI.
  # Overridable per-workspace via `agent.config["tier_models"]` (string keys).
  @default_tier_models %{
    "economy" => "gemini-2.5-flash-lite",
    "standard" => "gemini-2.5-flash",
    "premium" => "gemini-2.5-pro"
  }

  # Default tier → concrete model for the `agy` fork (bd-d2yut8). agy's model
  # catalogue does not overlap the upstream `gemini` CLI's at all (bd-2fzwlc),
  # so it gets its own map rather than sharing `@default_tier_models` — ids
  # are Operator-selected (2026-09-17) and include a `flagship` tier routed to
  # a Claude/GPT-bucket model. Also overridable via `agent.config["tier_models"]`.
  @agy_tier_models %{
    "economy" => "gemini-3.8-flash-low",
    "standard" => "gemini-3.8-flash-medium",
    "premium" => "gemini-3.1-pro-high",
    "flagship" => "claude-opus-4-6-thinking"
  }

  # Default thinking → CLI argv tokens: agy/gemini accept reasoning effort via
  # `--effort <level>`. `none` omits the flag entirely so the CLI's own
  # default applies. Workspaces can override per-level argv with
  # `agent.config["thinking_argv"]` (e.g. `--thinking-budget 8192`) if a CLI
  # surface needs something else.
  @default_thinking_argv %{
    "none" => [],
    "low" => ["--effort", "low"],
    "medium" => ["--effort", "medium"],
    "high" => ["--effort", "high"],
    # #1519: routing emits `xhigh`/`max` at the top of the difficulty scale,
    # but the effort ladder stops at "high" — clamp rather than silently
    # dropping the flag (mirrors `thinking_env/1`'s clamp below).
    "xhigh" => ["--effort", "high"],
    "max" => ["--effort", "high"]
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
    raw =
      (get_in(config || %{}, [Atom.to_string(role), "config"]) || %{})
      |> ProviderConfig.apply_overrides(@provider)

    Process.put(@pdict_key, CredentialsRef.embed_secrets(raw, Workspace.secrets_map(workspace)))
    :ok
  end

  def put_active(%{} = raw, _role) do
    Process.put(@pdict_key, ProviderConfig.apply_overrides(raw, @provider))
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
  `"premium"` | `"flagship"`) to a concrete model name for the given
  executable (`:gemini`, the default, or `:agy`). Returns `nil` for an
  unknown / nil tier — the adapter falls back to its CLI default.

  Workspace config can override the mapping under
  `agent.config["tier_models"]`, applied regardless of executable. Missing
  keys fall back to the built-in per-executable default — see
  `default_tier_models/1`.
  """
  @spec model_for_tier(String.t() | nil, :agy | :gemini) :: String.t() | nil
  def model_for_tier(tier, executable \\ :gemini)
  def model_for_tier(nil, _executable), do: nil
  def model_for_tier("", _executable), do: nil

  def model_for_tier(tier, executable) when is_binary(tier) do
    {:ok, cfg} = resolve()
    overrides = stringy_map(Map.get(cfg.raw, "tier_models"))
    base = default_tier_models(executable)

    case Map.get(overrides, tier) || Map.get(base, tier) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  def model_for_tier(_tier, _executable), do: nil

  @doc """
  Resolve an abstract `thinking` level to a list of CLI argv tokens to
  append to the spawn command, for the given executable (`:gemini`, the
  default, or `:agy`).

  Only `agy` accepts a `--effort <level>` flag (bd-d2yut8) — the upstream
  `gemini` CLI has no such flag (`Unknown argument: effort`, confirmed live
  against gemini-cli), so the `:gemini` branch always returns `[]`
  regardless of level or workspace override; its reasoning knob is surfaced
  via the `GEMINI_THINKING_LEVEL` env var instead (see `thinking_env/1`).
  For `:agy`, `low`/`medium`/`high` map to `["--effort", level]`, `none` /
  `nil` map to `[]`, and the workspace can override per-level argv via
  `agent.config["thinking_argv"]`.
  """
  @spec thinking_argv(String.t() | nil, :agy | :gemini) :: [String.t()]
  def thinking_argv(level, executable \\ :gemini)
  def thinking_argv(nil, _executable), do: []
  def thinking_argv("", _executable), do: []
  def thinking_argv("none", _executable), do: []
  def thinking_argv(_level, :gemini), do: []

  def thinking_argv(level, :agy) when is_binary(level) do
    {:ok, cfg} = resolve()
    overrides = list_map(Map.get(cfg.raw, "thinking_argv"))

    case Map.get(overrides, level) || Map.get(@default_thinking_argv, level) do
      argv when is_list(argv) -> argv
      _ -> []
    end
  end

  def thinking_argv(_level, _executable), do: []

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

  # #1519: routing emits `xhigh`/`max` at the top of the difficulty scale, but
  # Gemini's own ladder stops at "high". Clamp rather than fall through to the
  # catch-all, which would export NOTHING and quietly leave a D4/D5 Gemini
  # dispatch with less reasoning budget than a D3 one.
  def thinking_env(level) when level in ["xhigh", "max"] do
    [{"GEMINI_THINKING_LEVEL", "high"}]
  end

  def thinking_env(_), do: []

  @doc """
  Built-in default tier → model map for the given executable
  (`:gemini`, the default, or `:agy`; testing / introspection).
  """
  @spec default_tier_models(:agy | :gemini) :: %{String.t() => String.t()}
  def default_tier_models(executable \\ :gemini)
  def default_tier_models(:agy), do: @agy_tier_models
  def default_tier_models(_gemini), do: @default_tier_models

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
