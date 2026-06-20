defmodule Arbiter.MCP.Scope do
  @moduledoc """
  The capability model for an `Arbiter.MCP` connection — and its single
  enforcement point.

  Capability is a pure function of the bearer token presented on the MCP
  connection, not a code fork. The token is a signed, expiring blob
  (`Arbiter.MCP.mint/2` / `verify/2`) carrying the claims below; this module
  mints those tokens per spawn, decodes a presented token back into a `%Scope{}`,
  and answers the capability questions the transport and tool handlers ask
  (`from_token/1`, `own_task/2`, `same_workspace?/2`).

  ## Tiers

      %Arbiter.MCP.Scope{
        tier:         :worker | :coordinator,
        workspace_id: "uuid" | nil,    # worker: the bound workspace; coordinator: nil (workspace-agnostic)
        task_id:      "bd-…" | nil,    # worker tier: the one task it may read/progress
        repo:         "shipyard" | nil,# worker tier: its repo
        can_dispatch:    false | true,    # coordinator-only; the recursion guardrail
        depth:        0                # dispatch-recursion depth (Phase 2 guardrail)
      }

  | Tier | Reads | Writes | Dispatch |
  |---|---|---|---|
  | `:worker` | its own task, its mailbox, its workspace config | progress/qa/deployment notes on **its own task**; flags to siblings | never |
  | `:coordinator` | across any workspace on the installation | create/update/close tasks, deps (incl. `parent_of` grouping); dispatch | yes |

  The `:worker` tier is deliberately narrow — it must not list arbitrary tasks,
  dispatch, or touch another task's state, and it is **workspace-scoped**: a worker
  token carries the workspace it was dispatched into and can never reach another.
  Tier-level tool visibility is declared in `Arbiter.MCP.Catalog`; the data-level
  checks (own-task, workspace isolation) live here so handlers cannot accidentally
  skip them.

  ## Workspace-agnostic coordinators

  A coordinator token is **not** bound to a workspace at mint time (its
  `workspace_id` is `nil`): a single coordinator token orchestrates across every
  workspace on the installation. Coordinator-facing tools resolve the target
  workspace per call (explicit `workspace` arg → the referenced entity's own
  workspace → the installation default). Legacy workspace-bound coordinator
  tokens (minted with an explicit workspace before this change) still decode and
  stay scoped to that one workspace — `same_workspace?/2` honors both shapes.
  """

  alias Arbiter.MCP

  @enforce_keys [:tier]
  defstruct tier: nil,
            workspace_id: nil,
            task_id: nil,
            repo: nil,
            can_dispatch: false,
            depth: 0

  @type tier :: :worker | :coordinator

  @type t :: %__MODULE__{
          tier: tier(),
          workspace_id: String.t() | nil,
          task_id: String.t() | nil,
          repo: String.t() | nil,
          can_dispatch: boolean(),
          depth: non_neg_integer()
        }

  @doc "The valid tier atoms."
  @spec tiers() :: [tier()]
  def tiers, do: [:worker, :coordinator]

  # ---- minting ------------------------------------------------------------

  @doc """
  Mint a `:worker`-tier scope token for a slung task. The task's id, workspace,
  and repo are baked into the claims, so the token *is* the worker's identity —
  it can only ever read/progress that one task. Never carries `can_dispatch`.

  `task` is anything exposing `:id` and `:workspace_id` (an `Arbiter.Tasks.Issue`).
  """
  @spec mint_worker(%{id: String.t(), workspace_id: String.t()}, String.t() | nil, keyword()) ::
          String.t()
  def mint_worker(%{id: task_id, workspace_id: ws_id}, repo \\ nil, opts \\ [])
      when is_binary(task_id) and is_binary(ws_id) do
    %{
      tier: :worker,
      workspace_id: ws_id,
      task_id: task_id,
      repo: repo,
      can_dispatch: false,
      depth: Keyword.get(opts, :depth, 0)
    }
    |> MCP.mint(opts)
  end

  @doc """
  Mint a `:coordinator`-tier scope token. The first consumer is the operator's
  own tooling; a future autonomous coordinator presents the same token.
  Carries `can_dispatch: true` by default (override via opts) — the Phase 2
  dispatch-recursion guardrail reads it together with `:depth`.

  `workspace_id` defaults to `nil`, minting a **workspace-agnostic** token valid
  for any workspace on the installation — the path the `arb mcp token mint` /
  `POST /api/mcp/tokens` callers take. An explicit workspace id may still be
  passed to mint a legacy workspace-bound coordinator (used by some transport
  tests); such a token stays scoped to that one workspace.
  """
  @spec mint_coordinator(String.t() | nil, keyword()) :: String.t()
  def mint_coordinator(workspace_id \\ nil, opts \\ [])
      when is_binary(workspace_id) or is_nil(workspace_id) do
    %{
      tier: :coordinator,
      workspace_id: workspace_id,
      task_id: nil,
      repo: nil,
      can_dispatch: Keyword.get(opts, :can_dispatch, true),
      depth: Keyword.get(opts, :depth, 0)
    }
    |> MCP.mint(opts)
  end

  # ---- verifying ----------------------------------------------------------

  @doc """
  Verify and decode a presented bearer token into a `%Scope{}`. Returns
  `{:error, :expired | :invalid}` for an expired, tampered, or malformed token
  (the transport rejects those with HTTP 401).
  """
  @spec from_token(String.t()) :: {:ok, t()} | {:error, :expired | :invalid}
  def from_token(token) when is_binary(token) do
    case MCP.verify(token) do
      {:ok, claims} -> from_claims(claims)
      {:error, reason} -> {:error, reason}
    end
  end

  def from_token(_), do: {:error, :invalid}

  defp from_claims(%{tier: :worker, workspace_id: ws, task_id: task} = c)
       when is_binary(ws) and is_binary(task) do
    {:ok,
     %__MODULE__{
       tier: :worker,
       workspace_id: ws,
       task_id: task,
       repo: nilable_string(c[:repo]),
       can_dispatch: false,
       depth: depth(c[:depth])
     }}
  end

  # A coordinator claim decodes whether or not it carries a workspace: a
  # workspace-agnostic token (`workspace_id: nil`, the current mint shape) and a
  # legacy workspace-bound token both land here.
  #
  # Backward compat: `can_sling` was the claim key before it was renamed to
  # `can_dispatch` in the Tier-B vernacular rename. Tokens minted before that
  # rename carry `can_sling: true` and must still decode as can_dispatch: true.
  defp from_claims(%{tier: :coordinator} = c) do
    {:ok,
     %__MODULE__{
       tier: :coordinator,
       workspace_id: nilable_string(c[:workspace_id]),
       task_id: nil,
       repo: nil,
       can_dispatch: c[:can_dispatch] == true or c[:can_sling] == true,
       depth: depth(c[:depth])
     }}
  end

  defp from_claims(_), do: {:error, :invalid}

  defp nilable_string(s) when is_binary(s) and s != "", do: s
  defp nilable_string(_), do: nil

  defp depth(d) when is_integer(d) and d >= 0, do: d
  defp depth(_), do: 0

  # ---- data-level enforcement --------------------------------------------

  @doc """
  Resolve and authorize the task id a tool may act on for this scope.

    * `:worker` — the requested id must be `nil` (defaults to the bound task) or
      exactly the bound task. Any other id is `{:error, :unauthorized}` — a
      worker cannot read or progress another task through its token.
    * `:coordinator` — the requested id is required (a non-empty binary) and used
      verbatim; a missing id is `{:error, :missing}` so the handler can surface a
      usable "id is required" rather than guessing.
  """
  @spec own_task(t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :missing}
  def own_task(%__MODULE__{tier: :worker, task_id: bound}, nil), do: {:ok, bound}
  def own_task(%__MODULE__{tier: :worker, task_id: bound}, bound), do: {:ok, bound}
  def own_task(%__MODULE__{tier: :worker}, _other), do: {:error, :unauthorized}
  def own_task(%__MODULE__{tier: :coordinator}, id) when is_binary(id) and id != "", do: {:ok, id}
  def own_task(%__MODULE__{tier: :coordinator}, _), do: {:error, :missing}

  @doc """
  Whether this scope may act on a resource in `workspace_id`.

    * A **workspace-bound** scope (every worker, a legacy bound coordinator) may
      act only within its own workspace; a cross-workspace resource is treated as
      not-found by the handlers (so existence does not leak across workspaces).
    * A **workspace-agnostic** coordinator (`workspace_id: nil`) may act in any
      workspace — the per-call workspace resolution (`Arbiter.MCP.Tools`) decides
      which one, this only answers "is the scope allowed to".
  """
  @spec same_workspace?(t(), String.t() | nil) :: boolean()
  def same_workspace?(%__MODULE__{tier: :coordinator, workspace_id: nil}, ws) when is_binary(ws),
    do: true

  def same_workspace?(%__MODULE__{workspace_id: ws}, ws) when is_binary(ws), do: true
  def same_workspace?(%__MODULE__{}, _), do: false
end
