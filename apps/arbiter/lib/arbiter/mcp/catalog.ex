defmodule Arbiter.MCP.Catalog do
  @moduledoc """
  The `Arbiter.MCP` tool catalog: the declarative list of Phase 1 tools (name,
  the tiers that may call each, a one-line description, and a JSON Schema for the
  inputs) plus the dispatch path that the transport (`ArbiterWeb.MCP.Plug`) drives
  for `tools/list` and `tools/call`.

  Tier-level visibility is the **only** capability decision made here: a tool is
  visible to — and callable by — a scope iff the scope's tier is in the tool's
  `:tiers`. Data-level rules (own-bead, workspace isolation) live in the handlers
  (`Arbiter.MCP.Tools`) via `Arbiter.MCP.Scope`.

  ## Phase 1 catalog

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `bead_show` | polecat, coordinator | `Ash.get(Issue, id)` |
  | `bead_ready` | coordinator | `Issue.ready/1` |
  | `convoy_status` | polecat, coordinator | `Ash.get(Convoy, id)` + calcs |
  | `inbox_check` | polecat, coordinator | `Messages.inbox/2` + `mark_read` |
  | `workspace_show` | polecat, coordinator | `Ash.get(Workspace, id)` |
  | `bead_update_progress` | polecat, coordinator | `Ash.update(issue, …, action: :update)` |
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  # JSON-RPC / MCP error codes. -32003 is an implementation-defined server error
  # in the reserved -32000..-32099 range; -32602 is "invalid params".
  @code_not_permitted -32_003
  @code_invalid_params -32_602

  @type tool :: %{
          name: String.t(),
          tiers: [Scope.tier()],
          description: String.t(),
          input_schema: map(),
          handler: (Scope.t(), map() -> {:ok, map()} | {:error, {atom(), String.t()}})
        }

  @type call_result ::
          {:ok, map()}
          | {:rpc_error, integer(), String.t()}
          | {:tool_error, String.t()}

  @both [:polecat, :coordinator]

  @tools [
    %{
      name: "bead_show",
      tiers: @both,
      description:
        "Read one bead (id, title, status, notes, tracker, …). A polecat reads its own bead " <>
          "(the `id` argument may be omitted); a coordinator must pass the `id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Bead id (e.g. \"bd-dem49g\"). Optional for a polecat (defaults to its own bead)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.bead_show/2
    },
    %{
      name: "bead_ready",
      tiers: [:coordinator],
      description: "List ready (open, unblocked) beads in the workspace.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.bead_ready/2
    },
    %{
      name: "convoy_status",
      tiers: @both,
      description:
        "Convoy progress (open/closed member counts). A polecat may only query a convoy its " <>
          "bead belongs to.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Convoy id (e.g. \"bd-cv-3o8abc\")."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.convoy_status/2
    },
    %{
      name: "inbox_check",
      tiers: @both,
      description:
        "Read (and mark read) the unread mailbox for a bead — the structured replacement for " <>
          "`arb inbox`. A polecat checks its own bead; a coordinator passes `bead_id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "bead_id" => %{
            "type" => "string",
            "description" =>
              "Recipient bead id. Optional for a polecat (defaults to its own bead)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.inbox_check/2
    },
    %{
      name: "workspace_show",
      tiers: @both,
      description:
        "Show the scope's own workspace: config, vernacular, and acolyte security posture.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_show/2
    },
    %{
      name: "bead_update_progress",
      tiers: @both,
      description:
        "Record progress / completion notes on a bead — `notes`, `qa_notes`, `deployment_notes` " <>
          "only (the structured replacement for `arb issue update --qa-notes …`). A polecat may " <>
          "only update its own bead and cannot change status or priority.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Bead id. Optional for a polecat (defaults to its own bead)."
          },
          "notes" => %{"type" => "string", "description" => "Free-form progress / working notes."},
          "qa_notes" => %{"type" => "string", "description" => "What QA should verify."},
          "deployment_notes" => %{
            "type" => "string",
            "description" => "Rollout / backout considerations."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.bead_update_progress/2
    }
  ]

  @doc "All Phase 1 tool definitions, regardless of tier."
  @spec all() :: [tool()]
  def all, do: @tools

  @doc "The tool definitions visible to `scope` (those whose `:tiers` include the scope's tier)."
  @spec visible(Scope.t()) :: [tool()]
  def visible(%Scope{tier: tier}), do: Enum.filter(@tools, &(tier in &1.tiers))

  @doc "Look up a tool definition by name."
  @spec fetch(String.t()) :: {:ok, tool()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc """
  Authorize and execute a `tools/call`. Returns a normalized result the transport
  renders:

    * `{:ok, data}` — success (→ a tool result with `structuredContent`);
    * `{:rpc_error, code, message}` — unknown tool, or a scope/tier violation
      (→ a JSON-RPC error object, never a transport error);
    * `{:tool_error, message}` — an operational failure such as not-found or bad
      arguments (→ a tool result with `isError: true`).
  """
  @spec call(Scope.t(), String.t(), map()) :: call_result()
  def call(%Scope{} = scope, name, arguments) when is_binary(name) do
    args = if is_map(arguments), do: arguments, else: %{}

    case fetch(name) do
      :error ->
        {:rpc_error, @code_invalid_params, "Unknown tool: #{name}"}

      {:ok, tool} ->
        if scope.tier in tool.tiers do
          run(tool, scope, args)
        else
          {:rpc_error, @code_not_permitted,
           "Tool #{name} is not permitted for a #{scope.tier} scope"}
        end
    end
  end

  defp run(tool, scope, args) do
    case tool.handler.(scope, args) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, {:unauthorized, msg}} -> {:rpc_error, @code_not_permitted, msg}
      {:error, {_kind, msg}} when is_binary(msg) -> {:tool_error, msg}
    end
  rescue
    e -> {:tool_error, "tool #{tool.name} failed: #{Exception.message(e)}"}
  end
end
