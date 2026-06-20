defmodule Arbiter.Agents.Routing.Policy do
  @moduledoc """
  Behaviour for the function `(task, workspace, ledger_snapshot) → agent
  choice`.

  A routing policy decides which agent adapter + config to use for a given
  task at dispatch time. It is intentionally a *thin* layer above
  `Arbiter.Agents` (the dispatcher): the dispatcher resolves the workspace
  default; the policy can override it per-task based on priority, budget,
  or any other signal.

  Today the default policy (`Arbiter.Agents.Routing.Static`) returns
  `workspace.config["agent"]` unchanged — i.e. today's behavior, with the
  seam in place for `:by_priority`, `:by_budget`, `:round_robin` once the
  ledger has data to drive them (see `docs/agent-harness-design.md` §4.4).

  ## Return value shape

      %{
        type: :claude,                 # adapter type atom — resolves through Agents.for_type/1
        config: %{                     # adapter-specific config map (model, etc.)
          "model" => "sonnet"
        }
      }

  The `config` map is merged into the adapter's spawn opts — adapters
  decide how to consume it (e.g. Claude reads `"model"`).
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type choice :: %{type: atom(), config: map()}
  @type ledger_snapshot :: map()

  @callback choose(task :: Issue.t(), workspace :: Workspace.t() | nil, ledger_snapshot) ::
              choice
end
