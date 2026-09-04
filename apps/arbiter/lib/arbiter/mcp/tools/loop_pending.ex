defmodule Arbiter.MCP.Tools.LoopPending do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the Stage 2 loop-proposal queue (bd-9j2g3x):
  `loop_pending_list` / `loop_pending_diff` / `loop_pending_apply` /
  `loop_pending_reject`. Split out of `Arbiter.MCP.Tools` (see its moduledoc)
  — called back into for the generic arg/serialization helpers it still owns.

  Every tool here is coordinator-only in the catalog: a fleet-wide skill patch
  or a config change is not a worker's decision to make, and a worker bound to
  one task has no business applying a write that lands on every other task.
  There is no auto-apply at any evidence level — these tools exist so a human
  (or the coordinator acting for one) can read the diff first.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  require Logger

  @loop_states ~w(proposed hypothesis applied rejected superseded)a
  @loop_kinds ~w(skill_patch skill_create difficulty_override config_set repo_doc_patch)a

  # ---- loop_pending_list ---------------------------------------------------

  @doc """
  List queued loop proposals. Coordinator only. Optional `state` (one name or a
  list; defaults to the live states `hypothesis` + `proposed`), `kind`,
  `workspace`, `limit`. Returns summaries plus the workspace's evidence bar, so
  the caller can see how far a `hypothesis` still has to go.
  """
  @spec loop_pending_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def loop_pending_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args),
         {:ok, states} <- loop_states(args),
         {:ok, kind} <- Tools.optional_enum(args, "kind", @loop_kinds),
         {:ok, limit} <- Tools.optional_integer(args, "limit") do
      rows =
        [state: states || Arbiter.Loop.live_states()]
        |> Tools.maybe_put_kw(:kind, kind)
        |> Tools.maybe_put_kw(:workspace_id, ws_id)
        |> Tools.maybe_put_kw(:limit, limit)
        |> Arbiter.Loop.list_pending()

      {:ok,
       %{
         pending: Enum.map(rows, &serialize_pending_summary/1),
         count: length(rows),
         evidence_bar: Arbiter.Loop.evidence_bar(ws_id)
       }}
    end
  end

  # ---- loop_pending_diff ----------------------------------------------------

  @doc """
  One queued loop proposal in full, including its unified `diff` and — when it
  is not applicable yet — the reason why. Coordinator only.
  """
  @spec loop_pending_diff(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def loop_pending_diff(%Scope{} = scope, args) do
    with {:ok, row} <- fetch_pending(scope, args) do
      {:ok, serialize_pending(row)}
    end
  end

  # ---- loop_pending_apply ---------------------------------------------------

  @doc """
  Apply a queued loop proposal. Coordinator only. Dispatches on `kind` to the
  same public domain API a human would call, so the write lands with a normal
  paper-trail version attributed to the proposal id. Refuses anything that is
  not `proposed` — a `hypothesis` reply names its current evidence and what is
  still missing.
  """
  @spec loop_pending_apply(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def loop_pending_apply(%Scope{} = scope, args) do
    with {:ok, row} <- fetch_pending(scope, args) do
      case Arbiter.Loop.apply_pending(row, actor: Arbiter.PaperTrail.actor_label(scope)) do
        {:ok, applied} ->
          Logger.info("[loop_pending_apply] proposal #{applied.id} (#{applied.kind}) applied")
          {:ok, applied |> serialize_pending() |> Map.put(:applied, true)}

        {:error, reason} ->
          {:error, loop_error(reason)}
      end
    end
  end

  # ---- loop_pending_reject --------------------------------------------------

  @doc """
  Soft-reject a queued loop proposal with an optional `reason`. Coordinator
  only. The row persists as `rejected` (never deleted), so later windows
  reinforce its evidence in place instead of re-proposing it from scratch.
  """
  @spec loop_pending_reject(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def loop_pending_reject(%Scope{} = scope, args) do
    with {:ok, row} <- fetch_pending(scope, args) do
      opts =
        [actor: Arbiter.PaperTrail.actor_label(scope)]
        |> Tools.maybe_put_kw(:reason, Tools.fetch_string(args, "reason"))

      case Arbiter.Loop.reject_pending(row, opts) do
        {:ok, rejected} ->
          {:ok, rejected |> serialize_pending() |> Map.put(:rejected, true)}

        {:error, reason} ->
          {:error, loop_error(reason)}
      end
    end
  end

  # `state` accepts a single name or a list. Some clients JSON-encode the list
  # into a string despite the schema, so unwrap that shape first (bd-1dtufq).
  defp loop_states(args) do
    case Tools.unwrap_stringified_json(Map.get(args, "state"), [:list]) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      raw when is_binary(raw) ->
        with {:ok, state} <- Tools.enum_or_error(raw, "state", @loop_states), do: {:ok, [state]}

      raw when is_list(raw) ->
        Enum.reduce_while(raw, {:ok, []}, fn v, {:ok, acc} ->
          case Tools.enum_or_error(v, "state", @loop_states) do
            {:ok, state} -> {:cont, {:ok, acc ++ [state]}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      other ->
        {:error,
         {:invalid, "`state` must be a string or a list of strings, got #{inspect(other)}"}}
    end
  end

  # A proposal the caller's scope is allowed to see. A workspace-bound scope may
  # only reach rows in its own workspace; never one belonging to a different
  # workspace. `scope: :fleet` is the sole fleet marker — the row still
  # carries a real `workspace_id` (bd-3dasqm) and is visible in that workspace
  # only, not in every workspace, so it does not read as N findings when there
  # are N workspaces.
  defp fetch_pending(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.require_string(args, "id"),
         {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      case Arbiter.Loop.get_pending(id) do
        {:ok, row} ->
          if pending_visible?(row, ws_id),
            do: {:ok, row},
            else: {:error, {:not_found, "no loop proposal matching #{inspect(id)}"}}

        {:error, :not_found} ->
          {:error, {:not_found, "no loop proposal matching #{inspect(id)}"}}
      end
    end
  end

  # An unscoped (fleet-agnostic) caller sees everything; a workspace-bound
  # caller sees only its own rows, whatever their scope.
  defp pending_visible?(_row, nil), do: true
  defp pending_visible?(%{workspace_id: ws}, ws_id), do: ws == ws_id

  defp loop_error(:not_found), do: {:not_found, "no loop proposal matching that id"}

  defp loop_error({code, message}) when is_atom(code) and is_binary(message),
    do: {loop_error_code(code), message}

  defp loop_error(other), do: {:invalid, inspect(other)}

  # `:not_applicable` / `:unmapped` are the queue's own refusals; both are
  # caller errors rather than server faults, so they surface as `:invalid`.
  defp loop_error_code(:not_found), do: :not_found
  defp loop_error_code(_other), do: :invalid

  defp serialize_pending_summary(row) do
    %{
      id: row.id,
      kind: row.kind,
      state: row.state,
      scope: row.scope,
      gist: row.gist,
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks,
      context_cost_tokens: row.context_cost_tokens,
      target: row.target,
      category: row.category,
      applicable: Arbiter.Loop.applicable?(row),
      created_at: Tools.iso(row.created_at),
      updated_at: Tools.iso(row.updated_at)
    }
  end

  defp serialize_pending(row) do
    row
    |> serialize_pending_summary()
    |> Map.merge(%{
      diff: row.diff,
      payload: row.payload || %{},
      target_metric: row.target_metric,
      baseline: row.baseline,
      incident_refs: row.incident_refs,
      task_refs: row.task_refs,
      fingerprint: row.fingerprint,
      origin: row.origin,
      workspace_id: row.workspace_id,
      applied_at: Tools.iso(row.applied_at),
      escalated_at: Tools.iso(row.escalated_at),
      rejection_reason: row.rejection_reason,
      inapplicable_reason: Arbiter.Loop.inapplicable_reason(row)
    })
  end
end
