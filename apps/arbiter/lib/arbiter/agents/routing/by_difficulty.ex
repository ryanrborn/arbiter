defmodule Arbiter.Agents.Routing.ByDifficulty do
  @moduledoc """
  Routing policy: pick an agent config based on the task's `difficulty`
  (0..4 / D0..D4). Sibling to `:by_priority`; difficulty answers "how
  hard?" (drives model + thinking) while priority answers "how urgent?"
  (drives scheduling order). The two are orthogonal — both can be set on
  a task, and a workspace can opt into one or the other.

  ## Provider-agnostic abstractions

  The policy emits two abstract knobs in the chosen agent config:

    * `"model_tier"` — `"economy"` | `"standard"` | `"premium"`.
    * `"thinking"`   — `"none"` | `"low"` | `"medium"` | `"high"`
                       (abstract reasoning effort).

  Each adapter's `Config` maps these to its own concrete knobs:

    * Claude — tier → `haiku` / `sonnet` / `opus`;
      thinking → reasoning-effort flag.
    * Gemini — tier → `flash-lite` / `flash` / `pro`;
      thinking → thinkingBudget / reasoning flag.

  Routing rubric stays abstract; provider knobs live inside each adapter.

  ## Default mapping (D0..D4)

      D0 → economy  / none
      D1 → economy  / low
      D2 → standard / medium    ← also the fallback when difficulty is unset
      D3 → premium  / high
      D4 → premium  / high

  A task with `difficulty: nil` is treated as D2 (the common-feature
  default).

  ## Workspace overrides

  `workspace.config["routing"]["rules"]` is consulted with the task's
  difficulty key (`"D0".."D4"`). A matching rule is merged on top of the
  default mapping for that tier; any key the rule omits keeps the default.
  Unknown keys (e.g. a workspace that pins `"model"` directly) are
  passed through so power users can bypass the abstraction when needed.

  ## Example workspace config

      %{
        "agent" => %{
          "type" => "claude",
          "config" => %{}
        },
        "routing" => %{
          "policy" => "by_difficulty",
          "rules" => %{
            "D0" => %{"model_tier" => "economy", "thinking" => "none"},
            "D4" => %{"model_tier" => "premium", "thinking" => "high"}
          }
        }
      }

  A task with `difficulty: 2` (no rule) gets the D2 default
  (standard / medium); a task with `difficulty: 0` gets the rule above
  (economy / none).
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  # Default mapping: D0..D4 → {model_tier, thinking}. The Admiral signed
  # off on this exact table; do not adjust without re-litigation.
  @default_mapping %{
    0 => %{"model_tier" => "economy", "thinking" => "none"},
    1 => %{"model_tier" => "economy", "thinking" => "low"},
    2 => %{"model_tier" => "standard", "thinking" => "medium"},
    3 => %{"model_tier" => "premium", "thinking" => "high"},
    4 => %{"model_tier" => "premium", "thinking" => "high"}
  }

  # Unset difficulty is treated as D2 — the common-feature default.
  @default_difficulty 2

  @impl true
  def choose(%Issue{} = task, workspace, _ledger_snapshot) do
    default = Routing.default_choice(workspace)
    difficulty = effective_difficulty(task.difficulty)
    rule = merged_rule(workspace, difficulty)

    %{default | config: Map.merge(default.config, rule)}
  end

  @doc """
  Default mapping table (`%{0..4 => %{"model_tier" => _, "thinking" => _}}`).
  Exposed for tests / introspection; the Admiral signed off on the exact
  values.
  """
  @spec default_mapping() :: %{(0..4) => map()}
  def default_mapping, do: @default_mapping

  @doc """
  Returns the effective difficulty integer used for routing. `nil` →
  `#{@default_difficulty}` (D2). Out-of-range values are clamped to
  [0, 4] defensively (the schema constrains this, but the policy is
  called from places that pass arbitrary integers in tests).
  """
  @spec effective_difficulty(integer() | nil) :: 0..4
  def effective_difficulty(nil), do: @default_difficulty

  def effective_difficulty(n) when is_integer(n) do
    cond do
      n < 0 -> 0
      n > 4 -> 4
      true -> n
    end
  end

  def effective_difficulty(_), do: @default_difficulty

  # The merged rule = default for that tier, overridden by any
  # workspace-config rule for the same tier. Default keys survive when
  # the workspace rule omits them.
  defp merged_rule(workspace, difficulty) do
    base = Map.fetch!(@default_mapping, difficulty)
    override = workspace_rule_for(workspace, difficulty) || %{}
    Map.merge(base, override)
  end

  defp workspace_rule_for(nil, _difficulty), do: nil

  defp workspace_rule_for(%Workspace{config: config}, difficulty) do
    case get_in(config || %{}, ["routing", "rules", difficulty_key(difficulty)]) do
      rule when is_map(rule) -> rule
      _ -> nil
    end
  end

  defp difficulty_key(d) when d in 0..4, do: "D#{d}"
end
