defmodule Arbiter.Agents do
  @moduledoc """
  Entry point for autonomous-agent dispatch.

  Reads a workspace's `config["agent"]["type"]`, resolves the
  `Arbiter.Agents.Agent` adapter, and hands back the module. Callers should
  resolve through this dispatcher rather than referencing
  `Arbiter.Agents.Claude` directly — keeps adapter resolution centralized
  so workspace defaults and per-bead overrides behave consistently.

  Mirrors `Arbiter.Trackers` and `Arbiter.Mergers`. Phase B of the harness
  design (`docs/agent-harness-design.md`) intentionally ships only the
  `Claude` adapter — the seam exists so a future adapter (Codex / Aider /
  Gemini) can land without touching the polecat or the Tribunal.

  ## Resolution rule

  `workspace.config["agent"]["type"]` is one of the strings in
  `valid_agent_types/0` (`"claude"` today). Missing key falls back to
  `:claude` so existing workspaces — none of which carry an `"agent"`
  sub-object — see unchanged behavior.

  ## Reviewer dispatch

  The Tribunal's reviewer is a separate role with its own adapter slot
  under `config["review_agent"]`. Same shape as `config["agent"]`. Falls
  back to the worker agent's adapter (so a workspace that names
  `agent.type = "claude"` and omits `review_agent` gets a Claude reviewer
  automatically).
  """

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Gemini
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @type adapter :: module()

  @adapters %{
    claude: Claude,
    gemini: Gemini
  }

  @valid_agent_types ~w(claude gemini)

  @doc """
  Returns the adapter module for the given workspace.

  Resolves the agent type from `config["agent"]["type"]` (or `:claude` if
  unset) and looks it up in `adapters/0`.
  """
  @spec for_workspace(Workspace.t() | nil) :: adapter
  def for_workspace(nil), do: Claude
  def for_workspace(%Workspace{} = ws), do: for_type(agent_type(ws, :agent))

  @doc """
  Returns the reviewer adapter for the given workspace. Falls back to the
  worker agent's adapter when `review_agent` is not configured.
  """
  @spec reviewer_for_workspace(Workspace.t() | nil) :: adapter
  def reviewer_for_workspace(nil), do: Claude

  def reviewer_for_workspace(%Workspace{} = ws) do
    case agent_type(ws, :review_agent) do
      nil -> for_workspace(ws)
      type -> for_type(type)
    end
  end

  @doc """
  Returns the adapter module for a bead.

  Today there's no per-bead override (no `Issue.agent_type` column yet —
  see `docs/agent-harness-design.md` §4.2 Stage 2). For now the bead
  inherits the workspace's adapter. The signature accepts the bead +
  workspace so callers don't change when the per-bead override lands.
  """
  @spec for_bead(Issue.t(), Workspace.t() | nil) :: adapter
  def for_bead(%Issue{}, workspace), do: for_workspace(workspace)

  @doc """
  Returns the adapter module for an agent type atom.

  Raises if the type has no adapter registered (i.e. a type the codebase
  knows about but hasn't shipped yet — same shape as `Arbiter.Trackers`).
  """
  @spec for_type(atom()) :: adapter
  def for_type(type) when is_atom(type) do
    case Map.fetch(@adapters, type) do
      {:ok, mod} ->
        mod

      :error ->
        raise ArgumentError,
              "no agent adapter registered for #{inspect(type)} " <>
                "(registered: #{inspect(Map.keys(@adapters))})"
    end
  end

  @doc "Returns the map of agent_type → adapter module."
  @spec adapters() :: %{atom() => adapter}
  def adapters, do: @adapters

  @doc "Returns the list of valid agent type strings (for workspace-config validation)."
  @spec valid_agent_types() :: [String.t()]
  def valid_agent_types, do: @valid_agent_types

  @doc """
  Prepare the current process to make adapter calls for `workspace`.

  Seeds the adapter's per-process config (mirror of `Trackers.prepare/2`
  and `Mergers.prepare/1`) so subsequent `default_argv/2` / `spawn_env/1`
  calls in this process see the workspace's model + api_keys without
  threading the workspace through every call site.

  A `nil` workspace clears the per-process config (back to CLI defaults
  + ambient env auth). A no-op for unconfigured adapters.
  """
  @spec prepare(Workspace.t() | nil) :: :ok
  def prepare(workspace), do: prepare(workspace, :agent)

  @doc """
  Prepare the current process for either the worker `:agent` or the
  reviewer `:review_agent` role.

  Both roles share the same adapter machinery and the same per-process
  config dict — only one role's config can be active in a process at a
  time. The Tribunal seeds `:review_agent` before spawning the reviewer
  session; the polecat seeds `:agent` before spawning the worker.
  """
  @spec prepare(Workspace.t() | nil, :agent | :review_agent) :: :ok
  def prepare(nil, _role) do
    Claude.Config.put_active(nil)
    Gemini.Config.put_active(nil)
    :ok
  end

  def prepare(%Workspace{} = workspace, role) when role in [:agent, :review_agent] do
    Claude.Config.put_active(workspace, role)
    Gemini.Config.put_active(workspace, role)
    :ok
  end

  # ---- Internals --------------------------------------------------------

  defp agent_type(%Workspace{config: config}, role) do
    case get_in(config || %{}, [Atom.to_string(role), "type"]) do
      type when is_binary(type) ->
        try do
          String.to_existing_atom(type)
        rescue
          ArgumentError -> :claude
        end

      _ when role == :agent ->
        :claude

      _ ->
        nil
    end
  end
end
