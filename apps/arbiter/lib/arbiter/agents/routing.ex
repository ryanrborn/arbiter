defmodule Arbiter.Agents.Routing do
  @moduledoc """
  Model-tiering policy: pick which Claude model a dispatch should run on.

  This is the Phase A seam from `docs/agent-harness-design.md` — no new
  harness, no `Agent` behaviour yet. Sling and Tribunal both consult this
  module to decide which `--model` to pass into `ClaudeSession`, and the
  workspace config carries the policy.

  ## Config shape (extends `Workspace.config`, all keys optional)

      %{
        "agent" => %{
          "type" => "claude",
          "config" => %{
            "model" => "sonnet"           # static fallback for all dispatches
          },
          "review_agent" => %{
            "type" => "claude",
            "config" => %{"model" => "opus"}  # Tribunal reviewer model
          },
          "routing" => %{
            "policy" => "by_priority",    # "static" (default) | "by_priority"
            "rules" => %{                 # priority → model
              "P0" => "opus",
              "P1" => "opus",
              "P2" => "sonnet",
              "P3" => "sonnet",
              "P4" => "haiku"
            }
          }
        }
      }

  Either string (`"opus"`) or map (`%{"model" => "opus"}`) rule values are
  accepted — the map form is what the design doc shows and what we'll grow
  into when adapter-level config (api keys, region) lands on the same rule.

  ## Tribunal asymmetry

  `review_agent.config.model` is independent of `agent.config.model`. The
  default-design pattern is **cheaper acolyte, stronger reviewer** — e.g.
  worker on Sonnet, Tribunal on Opus — but the same shape works for the
  inverse (strong worker, cheap reviewer) if ledger data ever says so.

  ## Reversibility

  Clear `config["agent"]` (or leave it unset) and every dispatch falls back
  to the Claude CLI default model (no `--model` flag emitted). This is the
  "one config flip back to a single fixed model" the bead asks for.

  ## Per-dispatch override

  A caller (CLI `--model` flag, programmatic sling) can pass `:override`
  to `choose_work_model/3` / `choose_review_model/3` and it wins over every
  workspace policy. Per-bead column overrides (e.g. `Issue.agent_type`) are
  Phase B — not in this Phase A.
  """

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @doc """
  The default `priority → model` table the `by_priority` policy uses when a
  workspace enables the policy but doesn't supply its own `rules` map.

  Mirrors the recommendation in `docs/agent-harness-design.md` §4.3.
  """
  @spec default_priority_rules() :: %{String.t() => String.t()}
  def default_priority_rules do
    %{
      "P0" => "opus",
      "P1" => "opus",
      "P2" => "sonnet",
      "P3" => "sonnet",
      "P4" => "haiku"
    }
  end

  @doc """
  Resolve the worker model for a bead+workspace pair.

  Returns the model alias string (e.g. `"sonnet"`) or `nil`, which means
  "no `--model` flag — let the Claude CLI use its built-in default".

  Resolution order:
    1. `opts[:override]` (CLI `--model`, programmatic per-dispatch override)
    2. `config["agent"]["routing"]["policy"]` (`"by_priority"` → priority lookup)
    3. `config["agent"]["config"]["model"]` (static base)
    4. `nil`
  """
  @spec choose_work_model(Issue.t() | nil, Workspace.t() | nil, keyword()) :: String.t() | nil
  def choose_work_model(bead, workspace, opts \\ []) do
    case override(opts) do
      nil -> resolve_work(bead, workspace)
      m -> m
    end
  end

  @doc """
  Resolve the Tribunal reviewer model for a bead+workspace pair.

  Same override → review_agent → static fallback chain. The work model is
  the final fallback so a workspace that only sets `agent.config.model`
  still has the reviewer run on that same model (no surprise downgrade to
  the CLI default).
  """
  @spec choose_review_model(Issue.t() | nil, Workspace.t() | nil, keyword()) ::
          String.t() | nil
  def choose_review_model(bead, workspace, opts \\ []) do
    case override(opts) do
      nil -> resolve_review(bead, workspace)
      m -> m
    end
  end

  defp override(opts) do
    case Keyword.get(opts, :override) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp resolve_work(bead, workspace) do
    agent = agent_config(workspace)

    case routing_policy(agent) do
      "by_priority" -> by_priority_model(bead, agent) || static_model(agent)
      _ -> static_model(agent)
    end
  end

  defp resolve_review(bead, workspace) do
    agent = agent_config(workspace)
    review_agent = Map.get(agent, "review_agent", %{}) || %{}

    case review_static_model(review_agent) do
      nil -> resolve_work(bead, workspace)
      m -> m
    end
  end

  defp agent_config(%Workspace{config: %{} = config}) do
    Map.get(config, "agent", %{}) || %{}
  end

  defp agent_config(_workspace), do: %{}

  defp routing_policy(agent) do
    case Map.get(agent, "routing") do
      %{"policy" => policy} when is_binary(policy) -> policy
      _ -> "static"
    end
  end

  defp by_priority_model(%Issue{priority: priority}, agent) when is_integer(priority) do
    routing = Map.get(agent, "routing", %{}) || %{}
    rules = Map.get(routing, "rules") || default_priority_rules()
    key = priority_key(priority)

    case Map.get(rules, key) do
      m when is_binary(m) and m != "" -> m
      %{"model" => m} when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp by_priority_model(_bead, _agent), do: nil

  defp static_model(agent) do
    cond do
      is_binary(model = get_in(agent, ["config", "model"])) and model != "" ->
        model

      is_binary(model = Map.get(agent, "model")) and model != "" ->
        model

      true ->
        nil
    end
  end

  defp review_static_model(review_agent) do
    cond do
      is_binary(model = get_in(review_agent, ["config", "model"])) and model != "" ->
        model

      is_binary(model = Map.get(review_agent, "model")) and model != "" ->
        model

      true ->
        nil
    end
  end

  defp priority_key(0), do: "P0"
  defp priority_key(1), do: "P1"
  defp priority_key(2), do: "P2"
  defp priority_key(3), do: "P3"
  defp priority_key(4), do: "P4"
  defp priority_key(_), do: "P2"
end
