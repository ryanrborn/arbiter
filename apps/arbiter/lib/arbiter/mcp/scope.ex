defmodule Arbiter.MCP.Scope do
  @moduledoc """
  The capability model for an `Arbiter.MCP` connection — and its single
  enforcement point.

  Capability is a pure function of the bearer token presented on the MCP
  connection, not a code fork. The token is a signed, expiring blob
  (`Arbiter.MCP.mint/2` / `verify/2`) carrying the claims below; this module
  mints those tokens per spawn, decodes a presented token back into a `%Scope{}`,
  and answers the capability questions the transport and tool handlers ask
  (`from_token/1`, `own_bead/2`, `same_workspace?/2`).

  ## Tiers

      %Arbiter.MCP.Scope{
        tier:         :polecat | :coordinator,
        workspace_id: "uuid" | nil,    # polecat: the bound workspace; coordinator: nil (workspace-agnostic)
        bead_id:      "bd-…" | nil,    # polecat tier: the one bead it may read/progress
        rig:          "shipyard" | nil,# polecat tier: its rig
        can_dispatch:    false | true,    # coordinator-only; the recursion guardrail
        depth:        0                # dispatch-recursion depth (Phase 2 guardrail)
      }

  | Tier | Reads | Writes | Dispatch |
  |---|---|---|---|
  | `:polecat` | its own bead, its mailbox, its workspace config | progress/qa/deployment notes on **its own bead**; flags to siblings | never |
  | `:coordinator` | across any workspace on the installation | create/update/close beads, deps (incl. `parent_of` grouping); dispatch | yes |

  The `:polecat` tier is deliberately narrow — it must not list arbitrary beads,
  dispatch, or touch another bead's state, and it is **workspace-scoped**: a polecat
  token carries the workspace it was dispatched into and can never reach another.
  Tier-level tool visibility is declared in `Arbiter.MCP.Catalog`; the data-level
  checks (own-bead, workspace isolation) live here so handlers cannot accidentally
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
            bead_id: nil,
            rig: nil,
            can_dispatch: false,
            depth: 0

  @type tier :: :polecat | :coordinator

  @type t :: %__MODULE__{
          tier: tier(),
          workspace_id: String.t() | nil,
          bead_id: String.t() | nil,
          rig: String.t() | nil,
          can_dispatch: boolean(),
          depth: non_neg_integer()
        }

  @doc "The valid tier atoms."
  @spec tiers() :: [tier()]
  def tiers, do: [:polecat, :coordinator]

  # ---- minting ------------------------------------------------------------

  @doc """
  Mint a `:polecat`-tier scope token for a slung bead. The bead's id, workspace,
  and rig are baked into the claims, so the token *is* the polecat's identity —
  it can only ever read/progress that one bead. Never carries `can_dispatch`.

  `bead` is anything exposing `:id` and `:workspace_id` (an `Arbiter.Beads.Issue`).
  """
  @spec mint_polecat(%{id: String.t(), workspace_id: String.t()}, String.t() | nil, keyword()) ::
          String.t()
  def mint_polecat(%{id: bead_id, workspace_id: ws_id}, rig \\ nil, opts \\ [])
      when is_binary(bead_id) and is_binary(ws_id) do
    %{
      tier: :polecat,
      workspace_id: ws_id,
      bead_id: bead_id,
      rig: rig,
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
      bead_id: nil,
      rig: nil,
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

  defp from_claims(%{tier: :polecat, workspace_id: ws, bead_id: bead} = c)
       when is_binary(ws) and is_binary(bead) do
    {:ok,
     %__MODULE__{
       tier: :polecat,
       workspace_id: ws,
       bead_id: bead,
       rig: nilable_string(c[:rig]),
       can_dispatch: false,
       depth: depth(c[:depth])
     }}
  end

  # A coordinator claim decodes whether or not it carries a workspace: a
  # workspace-agnostic token (`workspace_id: nil`, the current mint shape) and a
  # legacy workspace-bound token both land here.
  defp from_claims(%{tier: :coordinator} = c) do
    {:ok,
     %__MODULE__{
       tier: :coordinator,
       workspace_id: nilable_string(c[:workspace_id]),
       bead_id: nil,
       rig: nil,
       can_dispatch: c[:can_dispatch] == true,
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
  Resolve and authorize the bead id a tool may act on for this scope.

    * `:polecat` — the requested id must be `nil` (defaults to the bound bead) or
      exactly the bound bead. Any other id is `{:error, :unauthorized}` — a
      polecat cannot read or progress another bead through its token.
    * `:coordinator` — the requested id is required (a non-empty binary) and used
      verbatim; a missing id is `{:error, :missing}` so the handler can surface a
      usable "id is required" rather than guessing.
  """
  @spec own_bead(t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :missing}
  def own_bead(%__MODULE__{tier: :polecat, bead_id: bound}, nil), do: {:ok, bound}
  def own_bead(%__MODULE__{tier: :polecat, bead_id: bound}, bound), do: {:ok, bound}
  def own_bead(%__MODULE__{tier: :polecat}, _other), do: {:error, :unauthorized}
  def own_bead(%__MODULE__{tier: :coordinator}, id) when is_binary(id) and id != "", do: {:ok, id}
  def own_bead(%__MODULE__{tier: :coordinator}, _), do: {:error, :missing}

  @doc """
  Whether this scope may act on a resource in `workspace_id`.

    * A **workspace-bound** scope (every polecat, a legacy bound coordinator) may
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
