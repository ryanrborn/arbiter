defmodule Arbiter.Agents.Claude.Config do
  @moduledoc """
  Reads the Claude agent's configuration from the active workspace.

  Mirrors `Arbiter.Trackers.Jira.Config` / `Arbiter.Mergers.Github.Config`:
  the per-process active config lives in the process dictionary, seeded by
  `Arbiter.Agents.prepare/1`. Long-lived callers (the polecat, the ReviewGate)
  seed once at the request boundary; adapters resolve through this module
  inside the request lifecycle.

  ## Workspace config shape

      %{
        "agent" => %{
          "type" => "claude",
          "config" => %{
            "model" => "sonnet",                          # one of "haiku" | "sonnet" | "opus"
            "credentials_ref" => "env:ANTHROPIC_API_KEY", # single-key default
            "api_keys" => [                               # multi-key rotation (optional)
              "env:ANTHROPIC_API_KEY",
              "env:ANTHROPIC_API_KEY_2"
            ]
          }
        },
        "review_agent" => %{
          "type" => "claude",
          "config" => %{ "model" => "opus" }
        },
        "routing" => %{
          "policy" => "by_priority",
          "rules" => %{
            "P0" => %{"model" => "opus"},
            "P1" => %{"model" => "opus"},
            "P2" => %{"model" => "sonnet"},
            "P3" => %{"model" => "sonnet"},
            "P4" => %{"model" => "haiku"}
          },
          "budget_usd_per_day" => nil
        }
      }

  All keys are optional. Missing config falls back to "let the CLI pick the
  model" — i.e. today's behavior, unchanged.

  ## Credential resolution

  `credentials_ref` (and each entry in `api_keys`) is a small DSL:

    * `"env:NAME"` — looks up `System.get_env("NAME")`.
    * A bare string with no prefix is treated as a literal token (test only —
      do not check credentials into workspace config).

  Unlike the Jira tracker, Claude doesn't *require* a credential to spawn —
  the upstream CLI authenticates against the user's local Claude Code login.
  So a missing credential is **not** an error here; `resolve_api_key/0`
  returns `nil` and the spawn inherits whatever auth the user already has.
  This keeps `start_claude: true` working in dev without forcing every
  workspace to declare an `ANTHROPIC_API_KEY` env var.
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

  # Default tier → concrete Claude model. Overridable per-workspace via
  # `agent.config["tier_models"]` (string keys). The values are the model
  # names the Claude CLI accepts via `--model`. Keeping these conservative
  # (haiku/sonnet/opus) so a new workspace doesn't have to define them.
  @default_tier_models %{
    "economy" => "haiku",
    "standard" => "sonnet",
    "premium" => "opus"
  }

  # Default thinking → effort flag passed to the Claude CLI via `--effort <level>`.
  # `none` omits the flag (CLI default).
  # Workspaces can override per-level argv with `agent.config["thinking_argv"]`
  # (e.g. swap to `--max-thinking-tokens` if a newer CLI prefers that).
  @default_thinking_argv %{
    "none" => [],
    "low" => ["--effort", "low"],
    "medium" => ["--effort", "medium"],
    "high" => ["--effort", "high"]
  }

  @doc """
  Set the active Claude agent config for the current process. Accepts a
  `Workspace` (reads its `config["agent"]["config"]`), a raw agent-config
  map, or `nil` to clear.

  Idempotent; safe to call from request setup. See `put_active/2` for the
  reviewer config (`review_agent`).
  """
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(thing), do: put_active(thing, :agent)

  @doc """
  Set the active config for either the worker `:agent` or the reviewer
  `:review_agent` role. The two share a shape; the policy / ReviewGate
  decides which one to seed.
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
  Resolve the active Claude config. Always returns `{:ok, t()}` — there's
  no required field for Claude (the CLI handles its own auth), so an empty
  active config is a valid "use CLI defaults" config.
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
  each call.

  Resolution order:

    1. If `api_keys` is set and non-empty, pick the next one by round-robin
       (per-process rotation counter). Resolved through the `"env:"` DSL.
    2. Else if `credentials_ref` is set, resolve it.
    3. Else `nil` (Claude CLI uses its own login).

  An `"env:..."` ref that points at an unset env var resolves to `nil`
  (not an error — see moduledoc).
  """
  @spec resolve_api_key() :: String.t() | nil
  def resolve_api_key do
    {:ok, cfg} = resolve()

    case cfg.api_keys do
      [] ->
        resolve_ref(cfg.credentials_ref)

      keys ->
        keys
        |> rotate_pick()
        |> resolve_ref()
    end
  end

  @doc """
  Return the active model name as a string, or `nil` if unset.

  Per-bead / per-dispatch overrides should be threaded through `:model` in
  the adapter's `opts` rather than reading this — that's the routing-policy
  seam. This helper is for the "no routing policy applied" path
  (`Routing.Static` default).
  """
  @spec active_model() :: String.t() | nil
  def active_model do
    {:ok, cfg} = resolve()
    cfg.model
  end

  @doc """
  Resolve an abstract `model_tier` (`"economy"` | `"standard"` |
  `"premium"`) to a concrete Claude model name. Returns `nil` for an
  unknown / nil tier — the adapter falls back to its CLI default.

  Workspace config can override the mapping under
  `agent.config["tier_models"]`. Missing keys fall back to the
  built-in default (`#{inspect(@default_tier_models)}`).
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
  Resolve an abstract `thinking` level (`"none"` | `"low"` | `"medium"` |
  `"high"`) to a list of CLI argv tokens to append to the spawn command.
  Returns `[]` for `nil` / unknown / `"none"`.

  Workspace config can override the per-level argv under
  `agent.config["thinking_argv"]`. Missing keys fall back to the built-in
  default (`--reasoning-effort <level>`).
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

  @doc "Built-in default tier → model map (testing / introspection)."
  def default_tier_models, do: @default_tier_models

  @doc "Built-in default thinking → argv map (testing / introspection)."
  def default_thinking_argv, do: @default_thinking_argv

  # ---- Internals --------------------------------------------------------

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

  # Filter a workspace-supplied map down to string→string entries.
  defp stringy_map(nil), do: %{}

  defp stringy_map(m) when is_map(m) do
    for {k, v} <- m, is_binary(k), is_binary(v) and v != "", into: %{}, do: {k, v}
  end

  defp stringy_map(_), do: %{}

  # Filter a workspace-supplied map down to string→list-of-strings entries.
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
