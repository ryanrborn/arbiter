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
        workspace_id: "uuid",          # every call is filtered to this workspace
        bead_id:      "bd-…" | nil,    # polecat tier: the one bead it may read/progress
        rig:          "shipyard" | nil,# polecat tier: its rig
        can_sling:    false | true,    # coordinator-only; the recursion guardrail
        depth:        0                # sling-recursion depth (Phase 2 guardrail)
      }

  | Tier | Reads | Writes | Sling |
  |---|---|---|---|
  | `:polecat` | its own bead, its mailbox, its workspace config | progress/qa/deployment notes on **its own bead**; flags to siblings | never |
  | `:coordinator` | across the workspace | create/update/close beads, deps (incl. `parent_of` grouping); sling | yes |

  The `:polecat` tier is deliberately narrow — it must not list arbitrary beads,
  sling, or touch another bead's state. Tier-level tool visibility is declared
  in `Arbiter.MCP.Catalog`; the data-level checks (own-bead, workspace isolation)
  live here so handlers cannot accidentally skip them.
  """

  alias Arbiter.MCP

  @enforce_keys [:tier, :workspace_id]
  defstruct tier: nil,
            workspace_id: nil,
            bead_id: nil,
            rig: nil,
            can_sling: false,
            depth: 0

  @type tier :: :polecat | :coordinator

  @type t :: %__MODULE__{
          tier: tier(),
          workspace_id: String.t(),
          bead_id: String.t() | nil,
          rig: String.t() | nil,
          can_sling: boolean(),
          depth: non_neg_integer()
        }

  @doc "The valid tier atoms."
  @spec tiers() :: [tier()]
  def tiers, do: [:polecat, :coordinator]

  # ---- minting ------------------------------------------------------------

  @doc """
  Mint a `:polecat`-tier scope token for a slung bead. The bead's id, workspace,
  and rig are baked into the claims, so the token *is* the polecat's identity —
  it can only ever read/progress that one bead. Never carries `can_sling`.

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
      can_sling: false,
      depth: Keyword.get(opts, :depth, 0)
    }
    |> MCP.mint(opts)
  end

  @doc """
  Mint a `:coordinator`-tier scope token for a workspace. The first consumer is
  the operator's own tooling; a future autonomous coordinator ("Mayor") presents
  the same token. Carries `can_sling: true` by default (override via opts) — the
  Phase 2 sling-recursion guardrail reads it together with `:depth`.
  """
  @spec mint_coordinator(String.t(), keyword()) :: String.t()
  def mint_coordinator(workspace_id, opts \\ []) when is_binary(workspace_id) do
    %{
      tier: :coordinator,
      workspace_id: workspace_id,
      bead_id: nil,
      rig: nil,
      can_sling: Keyword.get(opts, :can_sling, true),
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
       can_sling: false,
       depth: depth(c[:depth])
     }}
  end

  defp from_claims(%{tier: :coordinator, workspace_id: ws} = c) when is_binary(ws) do
    {:ok,
     %__MODULE__{
       tier: :coordinator,
       workspace_id: ws,
       bead_id: nil,
       rig: nil,
       can_sling: c[:can_sling] == true,
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
  Whether a resource's `workspace_id` is the one this scope is bound to. Every
  call is filtered to the scope's workspace; a cross-workspace resource is
  treated as not-found by the handlers (so existence does not leak across
  workspaces).
  """
  @spec same_workspace?(t(), String.t() | nil) :: boolean()
  def same_workspace?(%__MODULE__{workspace_id: ws}, ws) when is_binary(ws), do: true
  def same_workspace?(%__MODULE__{}, _), do: false
end
