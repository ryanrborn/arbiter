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
        session_id:   "uuid" | nil,    # browser-hosted session this token belongs to (revocable)
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
            session_id: nil,
            can_dispatch: false,
            depth: 0

  @type tier :: :worker | :coordinator

  @type t :: %__MODULE__{
          tier: tier(),
          workspace_id: String.t() | nil,
          task_id: String.t() | nil,
          repo: String.t() | nil,
          session_id: String.t() | nil,
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
  # `optional(atom()) => any()` keeps the map type OPEN. The doc above says
  # "anything exposing `:id` and `:workspace_id`", and the only caller
  # (`Arbiter.Worker.Dispatch.maybe_write_mcp_config/3`) passes a full
  # `%Arbiter.Tasks.Issue{}`; a closed two-key map type rejects it outright.
  @spec mint_worker(
          %{:id => String.t(), :workspace_id => String.t(), optional(atom()) => any()},
          String.t() | nil,
          keyword()
        ) :: String.t()
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
    |> MCP.mint(Keyword.put_new(opts, :max_age, MCP.worker_max_age()))
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

  @doc """
  Mint the `:coordinator`-tier token for one browser-hosted session
  (RFC §9.3, bd-aprlbb).

  Differs from `mint_coordinator/2` in exactly three ways, all of them
  deliberate:

    * It carries a `session_id` claim, which makes the token **revocable**.
      Scope tokens are stateless signed blobs with no revocation table
      (`Arbiter.MCP`'s incident-response note), so the session row is the
      handle: `from_token/1` refuses a token whose session has been ended,
      killed, or explicitly revoked. That is what lets "killing a session
      revokes its token" be true without rotating `SECRET_KEY_BASE` and
      invalidating every other token on the installation.
    * `can_dispatch` defaults **off** (§10.1: dispatch recursion is the
      documented guardrail and switching it on is a deliberate pre-launch
      choice), where `mint_coordinator/2` defaults it on.
    * `workspace_id` is `nil` for the cross-workspace default (decision 6) and
      bound for the opt-in single-workspace binding — the same two shapes
      `same_workspace?/2` already models.

  The session id also makes MCP audit rows attributable to the same session the
  usage ledger keys on.
  """
  @spec mint_session(String.t(), keyword()) :: String.t()
  def mint_session(session_id, opts \\ []) when is_binary(session_id) and session_id != "" do
    %{
      tier: :coordinator,
      workspace_id: nilable_string(Keyword.get(opts, :workspace_id)),
      task_id: nil,
      repo: nil,
      session_id: session_id,
      can_dispatch: Keyword.get(opts, :can_dispatch, false),
      depth: Keyword.get(opts, :depth, 0)
    }
    |> MCP.mint(opts)
  end

  # ---- verifying ----------------------------------------------------------

  @doc """
  Verify and decode a presented bearer token into a `%Scope{}`. Returns
  `{:error, :expired | :invalid}` for an expired, tampered, or malformed token,
  or `{:error, :revoked}` for a session token whose session has ended (the
  transport rejects all three with HTTP 401).

  The revocation check costs one indexed primary-key read, and **only** for a
  token that carries a `session_id` claim — worker and plain coordinator tokens
  never touch the database here. It lives in `from_token/1` rather than in the
  transport plug for the same reason `own_task/2` and `same_workspace?/2` do:
  this module is the single enforcement point, and a check a caller has to
  remember to make is a check that eventually gets skipped.
  """
  @spec from_token(String.t()) :: {:ok, t()} | {:error, :expired | :invalid | :revoked}
  def from_token(token) when is_binary(token) do
    with {:ok, claims} <- MCP.verify(token),
         {:ok, scope} <- from_claims(claims) do
      check_revocation(scope)
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
       session_id: nil,
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
       session_id: nilable_string(c[:session_id]),
       can_dispatch: c[:can_dispatch] == true or c[:can_sling] == true,
       depth: depth(c[:depth])
     }}
  end

  defp from_claims(_), do: {:error, :invalid}

  defp nilable_string(s) when is_binary(s) and s != "", do: s
  defp nilable_string(_), do: nil

  defp depth(d) when is_integer(d) and d >= 0, do: d
  defp depth(_), do: 0

  # A session token outlives nothing: the moment its row is ended, killed, or
  # explicitly revoked, the token stops verifying. A claim naming a session
  # with no row at all is revoked too — the row is the authority, and its
  # absence cannot mean "allow".
  defp check_revocation(%__MODULE__{session_id: nil} = scope), do: {:ok, scope}

  defp check_revocation(%__MODULE__{session_id: id} = scope) do
    if Arbiter.Sessions.mcp_token_revoked?(id), do: {:error, :revoked}, else: {:ok, scope}
  end

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
