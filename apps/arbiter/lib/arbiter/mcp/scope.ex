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
        tier:         :worker | :coordinator | :refine,
        workspace_id: "uuid" | nil,    # worker/refine: the bound workspace; coordinator: nil (workspace-agnostic)
        task_id:      "bd-…" | nil,    # worker tier: the one task it may read/progress
        issue_id:     "bd-…" | nil,    # refine tier: the bound issue whose subtree it may write
        repo:         "shipyard" | nil,# worker tier: its repo
        session_id:   "uuid" | nil,    # browser-hosted session this token belongs to (revocable)
        can_dispatch:    false | true,    # coordinator-only; the recursion guardrail
        depth:        0                # dispatch-recursion depth (Phase 2 guardrail)
      }

  | Tier | Reads | Writes | Dispatch |
  |---|---|---|---|
  | `:worker` | its own task, its mailbox, its workspace config | progress/qa/deployment notes on **its own task**; flags to siblings | never |
  | `:coordinator` | across any workspace on the installation | create/update/close tasks, deps (incl. `parent_of` grouping); dispatch | yes |
  | `:refine` | broadly across its **bound workspace** (tasks, graph reads, repos, skills, workspace config) | title/description/acceptance/typing/notes edits, `task_create`, dep edges and `task_promote` — **only inside the bound issue's `parent_of` subtree** | never |

  ## The `:refine` tier (bd-3uy2hn)

  A refine token is the capability behind a browser-hosted *refinement* session:
  it exists to turn one rough Backlog issue into a properly specified, broken-down
  and promotable one, and nothing else.

    * It is bound to a **workspace and an issue**, and carries a `session_id`, so
      it is revocable exactly like a phase-3 session token.
    * **Reads are broad on purpose** — refining an issue means reading its
      neighbours — but every **write** must land on the bound issue or a
      descendant reachable from it by `parent_of` (`subtree_member?/2`).
    * `can_dispatch` is **always** false, whatever the claim says. The tier, not
      the claim, decides: a refine session must never start work, only shape it.

  Which tools a refine token may call at all is one explicit table,
  `Arbiter.MCP.RefinePolicy` — allow or deny for *every* tool in the catalog,
  with no implicit default, so a newly added tool cannot silently inherit
  authority.

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
            issue_id: nil,
            repo: nil,
            session_id: nil,
            can_dispatch: false,
            depth: 0

  @type tier :: :worker | :coordinator | :refine

  @type t :: %__MODULE__{
          tier: tier(),
          workspace_id: String.t() | nil,
          task_id: String.t() | nil,
          issue_id: String.t() | nil,
          repo: String.t() | nil,
          session_id: String.t() | nil,
          can_dispatch: boolean(),
          depth: non_neg_integer()
        }

  @doc "The valid tier atoms."
  @spec tiers() :: [tier()]
  def tiers, do: [:worker, :coordinator, :refine]

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

  @doc """
  Mint a `:refine`-tier scope token: one browser-hosted refinement session, bound
  to one workspace and one issue (bd-3uy2hn).

  The claims are the binding. `workspace_id` and `issue_id` are both required —
  a refine token with either missing does not decode at all, because "unbound"
  can never mean "unrestricted" for a tier whose entire job is to be restricted.
  `session_id` makes it revocable the moment the session ends (see
  `mint_session/2`), and `can_dispatch` is hard-wired off: it is not an option
  here, and `from_claims/1` refuses to honour the claim even if some other minter
  sets it.
  """
  @spec mint_refine(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def mint_refine(session_id, workspace_id, issue_id, opts \\ [])
      when is_binary(session_id) and session_id != "" and is_binary(workspace_id) and
             workspace_id != "" and is_binary(issue_id) and issue_id != "" do
    %{
      tier: :refine,
      workspace_id: workspace_id,
      issue_id: issue_id,
      task_id: nil,
      repo: nil,
      session_id: session_id,
      can_dispatch: false,
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

  # A refine claim only decodes when *both* bindings are present: the workspace it
  # may read and the issue whose subtree it may write. `can_dispatch` is dropped
  # on the floor — the tier decides, not the claim.
  defp from_claims(%{tier: :refine, workspace_id: ws, issue_id: issue} = c)
       when is_binary(ws) and ws != "" and is_binary(issue) and issue != "" do
    {:ok,
     %__MODULE__{
       tier: :refine,
       workspace_id: ws,
       task_id: nil,
       issue_id: issue,
       repo: nil,
       session_id: nilable_string(c[:session_id]),
       can_dispatch: false,
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
    * `:refine` — a missing id defaults to the bound issue; any explicit id is
      accepted here, because reads across the workspace are deliberately broad.
      **This is not the write gate.** A refine write must additionally pass
      `subtree_member?/2`; `own_task/2` only resolves which task is being named.
  """
  @spec own_task(t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :missing}
  def own_task(%__MODULE__{tier: :worker, task_id: bound}, nil), do: {:ok, bound}
  def own_task(%__MODULE__{tier: :worker, task_id: bound}, bound), do: {:ok, bound}
  def own_task(%__MODULE__{tier: :worker}, _other), do: {:error, :unauthorized}
  def own_task(%__MODULE__{tier: :refine, issue_id: bound}, nil), do: {:ok, bound}

  def own_task(%__MODULE__{tier: :refine}, id) when is_binary(id) and id != "", do: {:ok, id}

  def own_task(%__MODULE__{tier: :refine}, _), do: {:error, :missing}

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

  @doc """
  Whether `task_id` lies inside a `:refine` scope's authority — the bound issue
  itself, or a descendant reachable from it by `parent_of` edges.

  This is the write gate for the refine tier, and it is deliberately `false` for
  every other tier: `:worker` and `:coordinator` have no subtree concept, so
  asking this question about them is a caller bug and the safe answer is "no".
  Handlers call `Arbiter.MCP.Tools.authorize_subtree/2`, which is tier-aware and
  is the function to reach for; this one answers only the graph question.
  """
  @spec subtree_member?(t(), String.t() | nil) :: boolean()
  def subtree_member?(%__MODULE__{tier: :refine, issue_id: bound}, task_id),
    do: Arbiter.Tasks.Dependencies.in_parent_subtree?(bound, task_id)

  def subtree_member?(%__MODULE__{}, _task_id), do: false
end
