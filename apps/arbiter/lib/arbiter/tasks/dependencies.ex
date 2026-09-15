defmodule Arbiter.Tasks.Dependencies do
  @moduledoc """
  The one domain entry point for dependency-edge writes (bd-apj0gq).

  Before this module, three call sites hand-rolled `Ash.create(Dependency, …)`
  with three different validation stories — MCP `dep_add` enforced
  same-workspace, `graph_add_edge` enforced same-workspace plus a narrower type
  set, and the REST controller (which `arb dep add` and `arb create --deps`
  route through) enforced nothing at all. Every surface now goes through
  `add/4` and `remove/3`, so every surface gets the same four guards:

    1. **Both endpoints must exist** — reported as `{:not_found, message}`.
    2. **Both endpoints must live in one workspace.** Adopted from MCP's rule.
       Cross-workspace edges half-worked before: readiness honoured them but
       `dep_remove` refused to touch them, so a REST-written one became a
       coordinator-invisible, coordinator-unremovable blocker. `add/4` refuses
       to create them; `remove/3` deliberately does **not** apply the check, so
       pre-existing ones stay removable.
    3. **No gating cycle.** `:depends_on` / `:blocks` are checked against the
       **global** gating edge set via `Arbiter.Tasks.DependencyGraph`, the same
       digraph check `Conductor.validate_acyclic/1` runs over a graph's members.
       Without it `A depends_on B` + `B depends_on A` persists happily and both
       issues are permanently non-ready — a silent deadlock. Non-gating types
       (`:relates_to`, `:discovered_from`, `:parent_of`, `:conflicts_with`) are
       never cycle-checked.
    4. **The resource's own rules** still apply: self-reference, the
       `unique_edge` identity, the type enum and both FKs.

  On top of the guards, both writers:

    * **Re-evaluate `Issue.maybe_auto_close/1`** for a `:parent_of` parent.
      `maybe_auto_close` was only ever reached from the `:close` action's
      after-transaction hook, i.e. only when a *child* closed — so attaching an
      already-closed child to an `auto_close` parent, or detaching its last open
      child, left the parent wrongly open. Edge writes now close that hole for
      MCP, REST, the CLI and the dashboard alike.
    * **Broadcast on `"tasks"` for both endpoints** (`Issue.broadcast_lifecycle
      (:updated, issue)`). `Dependency` has no PubSub of its own, and
      `TaskDetailLive` already refreshes its relationship panel on any task
      lifecycle event, so this is what makes a second tab repaint.

  ## Transactions and the cycle race

  `add/4` and `remove/3` each run their resolution, guards and writes inside one
  `Ash.transaction/2`. The cycle check is read-then-write and therefore racy
  across two simultaneous adds; under SQLite's single writer, running it inside
  the transaction is sufficient serialisation and no explicit lock is needed.

  Every guard runs *before* any write, so a guard failure has nothing to roll
  back — it simply returns without writing. A failure of the write itself
  (`Ash.create`, a raising `Ash.destroy!`) is rolled back by Ash. Broadcasts are
  sent *after* the transaction, so a failed write never announces itself.

  ## Error shape

  Facade guards return `{:error, {reason, message}}` with `reason` one of
  `:invalid_type`, `:not_found`, `:cross_workspace`, `:cyclic` — a uniform
  `{atom, binary}` that MCP renders as `{:invalid, message}` and the REST
  controller renders as a 400 `invalid_request`. Resource-level failures pass
  through unwrapped as `{:error, %Ash.Error.Invalid{}}`, so the REST fallback
  keeps returning 422 for a self-reference or a duplicate edge.
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type error_reason :: :invalid_type | :not_found | :cross_workspace | :cyclic
  @type error :: {error_reason(), String.t()} | Ash.Error.Invalid.t()

  @empty_groups %{
    blocked_by: [],
    blocks: [],
    parents: [],
    children: [],
    relates_to: [],
    discovered_from: [],
    discovered: [],
    conflicts_with: []
  }

  # ---- add ----------------------------------------------------------------

  @doc """
  Add a dependency edge from `from_id` to `to_id`.

  `type` may be an atom or a string; it must be one of `Dependency.types/0`.
  Options:

    * `:notes` — Markdown context on why the edge exists.
    * `:created_by` — actor label (e.g. `"dashboard"`, an MCP session).

  Returns `{:ok, %Dependency{}}`, or `{:error, {reason, message}}` for a facade
  guard, or `{:error, %Ash.Error.Invalid{}}` for a resource-level rejection.
  """
  @spec add(String.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, Dependency.t()} | {:error, error()}
  def add(from_id, to_id, type, opts \\ []) when is_binary(from_id) and is_binary(to_id) do
    with {:ok, type} <- cast_type(type) do
      transaction(fn ->
        with {:ok, from} <- fetch_issue(from_id),
             {:ok, to} <- fetch_issue(to_id),
             :ok <- same_workspace(from, to),
             :ok <- acyclic(from_id, to_id, type),
             {:ok, dep} <- create_edge(from_id, to_id, type, opts) do
          _ = reevaluate_auto_close(type, from)
          {:ok, dep}
        end
      end)
      |> after_commit(from_id, to_id)
    end
  end

  # ---- remove -------------------------------------------------------------

  @doc """
  Remove dependency edges between `from_id` and `to_id`.

  With `type` `nil`, every edge between the ordered pair is removed; with a
  type, only that one. Returns `{:ok, count}`; a removal that matched nothing is
  **not** an error — it normalises to `{:ok, 0}`, because the caller's intent
  ("this edge should not exist") is already satisfied.

  Unlike `add/4` this does not apply the cross-workspace guard: edges written
  before the guard existed must stay removable.
  """
  @spec remove(String.t(), String.t(), atom() | String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, error()}
  def remove(from_id, to_id, type \\ nil) when is_binary(from_id) and is_binary(to_id) do
    with {:ok, type} <- cast_optional_type(type) do
      transaction(fn ->
        case edges_between(from_id, to_id, type) do
          [] -> {:ok, 0}
          edges -> destroy_edges_and_reevaluate(edges, from_id)
        end
      end)
      |> case do
        {:ok, 0} -> {:ok, 0}
        other -> after_commit(other, from_id, to_id)
      end
    end
  end

  defp destroy_edges_and_reevaluate(edges, from_id) do
    Enum.each(edges, &Ash.destroy!/1)

    if Enum.any?(edges, &(&1.type == :parent_of)) do
      reevaluate_parent_auto_close(from_id)
    end

    {:ok, length(edges)}
  end

  defp reevaluate_parent_auto_close(from_id) do
    case fetch_issue(from_id) do
      {:ok, parent} -> reevaluate_auto_close(:parent_of, parent)
      _ -> :ok
    end
  end

  # ---- reads --------------------------------------------------------------

  @doc """
  Every edge touching `issue_id`, grouped by the **role** the other endpoint
  plays rather than by raw row direction.

  Direction alone is misleading: an epic's `:parent_of` children and its
  `:depends_on` blockers are both outbound rows but mean opposite things. The
  groups are:

    * `:blocked_by` — issues this one waits for (`depends_on` out, `blocks` in)
    * `:blocks` — issues waiting for this one (`depends_on` in, `blocks` out)
    * `:parents` / `:children` — `:parent_of` in / out
    * `:relates_to` / `:conflicts_with` — symmetric, both directions
    * `:discovered_from` — the sources this issue came from
    * `:discovered` — the issues discovered while working this one

  Each entry is `%{edge: %Dependency{}, issue_id: id, issue: %Issue{} | nil,
  direction: :outbound | :inbound}`. `:issue` is `nil` only if the other
  endpoint could not be loaded.
  """
  @spec for_issue(String.t()) :: %{atom() => [map()]}
  def for_issue(issue_id) when is_binary(issue_id) do
    edges =
      Dependency
      |> Ash.Query.filter(from_issue_id == ^issue_id or to_issue_id == ^issue_id)
      |> Ash.Query.sort(created_at: :asc)
      |> Ash.read!()

    issues = load_other_endpoints(edges, issue_id)

    edges
    |> Enum.reduce(@empty_groups, fn edge, acc ->
      {group, other_id, direction} = classify(edge, issue_id)

      entry = %{
        edge: edge,
        issue_id: other_id,
        issue: Map.get(issues, other_id),
        direction: direction
      }

      Map.update!(acc, group, &[entry | &1])
    end)
    |> Map.new(fn {group, entries} -> {group, Enum.reverse(entries)} end)
  end

  @doc """
  Would adding `from_id --type--> to_id` close a gating cycle?

  Always `false` for a non-gating type. Intended for pre-checks (greying out a
  candidate in a picker before the operator commits); `add/4` re-runs the same
  check inside its transaction, so this is advisory, not authoritative.
  """
  @spec would_cycle?(String.t(), String.t(), atom() | String.t()) :: boolean()
  def would_cycle?(from_id, to_id, type) do
    case cast_type(type) do
      {:ok, type} -> match?({:error, _}, acyclic(from_id, to_id, type))
      {:error, _} -> false
    end
  end

  # ---- guards -------------------------------------------------------------

  defp cast_type(type) when is_atom(type) and not is_nil(type) do
    if type in Dependency.types(),
      do: {:ok, type},
      else: {:error, {:invalid_type, invalid_type_message(type)}}
  end

  defp cast_type(type) when is_binary(type) do
    case Enum.find(Dependency.types(), &(Atom.to_string(&1) == type)) do
      nil -> {:error, {:invalid_type, invalid_type_message(type)}}
      atom -> {:ok, atom}
    end
  end

  defp cast_type(other), do: {:error, {:invalid_type, invalid_type_message(other)}}

  defp cast_optional_type(nil), do: {:ok, nil}
  defp cast_optional_type(type), do: cast_type(type)

  defp invalid_type_message(type) do
    "invalid dependency type #{inspect(type)} — expected one of " <>
      Enum.map_join(Dependency.types(), ", ", &Atom.to_string/1)
  end

  defp fetch_issue(id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      _ -> {:error, {:not_found, "task #{id} not found"}}
    end
  end

  defp same_workspace(%Issue{workspace_id: ws}, %Issue{workspace_id: ws}), do: :ok

  defp same_workspace(%Issue{} = from, %Issue{} = to) do
    {:error,
     {:cross_workspace,
      "#{from.id} is in workspace #{workspace_label(from)} and #{to.id} is in workspace " <>
        "#{workspace_label(to)} — relationships are within a single workspace"}}
  end

  defp workspace_label(%Issue{workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{name: name}} when is_binary(name) -> name
      _ -> ws_id
    end
  end

  # A self-edge is a degenerate cycle, but reporting it as one buries the real
  # problem. `RejectSelfReference` on the resource names it properly, so leave
  # it to the create.
  defp acyclic(id, id, _type), do: :ok

  defp acyclic(from_id, to_id, type) do
    if DependencyGraph.gating?(type) do
      candidate = DependencyGraph.normalize({type, from_id, to_id})

      # Only the candidate's own reachability, not "is anything cyclic": a
      # legacy cyclic pair elsewhere in the ledger must not veto an unrelated
      # edge, nor be named in its error.
      case DependencyGraph.candidate_cycle(candidate, DependencyGraph.gating_edges(:all)) do
        :ok ->
          :ok

        {:error, {:cyclic, cycle}} ->
          {:error,
           {:cyclic,
            "#{type} #{from_id} → #{to_id} would create a dependency cycle: " <>
              DependencyGraph.format_cycle(cycle)}}
      end
    else
      :ok
    end
  end

  # ---- writes -------------------------------------------------------------

  defp create_edge(from_id, to_id, type, opts) do
    %{from_issue_id: from_id, to_issue_id: to_id, type: type}
    |> maybe_put(:notes, Keyword.get(opts, :notes))
    |> maybe_put(:created_by, Keyword.get(opts, :created_by))
    |> then(&Ash.create(Dependency, &1))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp edges_between(from_id, to_id, nil) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from_id and to_issue_id == ^to_id)
    |> Ash.read!()
  end

  defp edges_between(from_id, to_id, type) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from_id and to_issue_id == ^to_id and type == ^type)
    |> Ash.read!()
  end

  # A `:parent_of` write changes the parent's child rollup, which is what
  # `auto_close` keys off. Every other type leaves it untouched.
  defp reevaluate_auto_close(:parent_of, %Issue{} = parent), do: Issue.maybe_auto_close(parent)
  defp reevaluate_auto_close(_type, _from), do: :ok

  # ---- transaction --------------------------------------------------------

  # `Ash.transaction/2` returns `{:ok, whatever_the_function_returned}`, and
  # short-circuits to exactly that when already inside a transaction (which is
  # the normal case under the test sandbox, and the case when the facade is
  # called from inside another action). Flatten it so callers see one shape.
  defp transaction(fun) do
    case Ash.transaction([Dependency, Issue], fun) do
      {:ok, {:ok, _} = ok} -> ok
      {:ok, {:error, _} = error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- post-commit --------------------------------------------------------

  defp after_commit({:ok, result}, from_id, to_id) do
    broadcast_endpoints(from_id, to_id)
    {:ok, result}
  end

  defp after_commit({:error, reason}, _from_id, _to_id), do: {:error, reason}

  # Reload so a parent that just auto-closed is announced with its new status,
  # and so a caller can't be handed a stale struct.
  defp broadcast_endpoints(from_id, to_id) do
    Enum.each([from_id, to_id], fn id ->
      case Ash.get(Issue, id) do
        {:ok, %Issue{} = issue} -> Issue.broadcast_lifecycle(:updated, issue)
        _ -> :ok
      end
    end)
  end

  # ---- for_issue helpers --------------------------------------------------

  # The group an edge belongs to, from the perspective of `issue_id`. Direction
  # alone is not enough: `parent_of` out means "my child", `depends_on` out means
  # "I am blocked by", and the panel must not conflate them.
  defp classify(edge, issue_id) do
    {group, direction} = classify_group(edge, issue_id)
    {group, other_endpoint(edge, issue_id), direction}
  end

  defp classify_group(%Dependency{type: :depends_on, from_issue_id: id}, id),
    do: {:blocked_by, :outbound}

  defp classify_group(%Dependency{type: :blocks, to_issue_id: id}, id),
    do: {:blocked_by, :inbound}

  defp classify_group(%Dependency{type: :depends_on, to_issue_id: id}, id),
    do: {:blocks, :inbound}

  defp classify_group(%Dependency{type: :blocks, from_issue_id: id}, id),
    do: {:blocks, :outbound}

  defp classify_group(%Dependency{type: :parent_of, from_issue_id: id}, id),
    do: {:children, :outbound}

  defp classify_group(%Dependency{type: :parent_of, to_issue_id: id}, id),
    do: {:parents, :inbound}

  defp classify_group(%Dependency{type: :discovered_from, from_issue_id: id}, id),
    do: {:discovered_from, :outbound}

  defp classify_group(%Dependency{type: :discovered_from, to_issue_id: id}, id),
    do: {:discovered, :inbound}

  defp classify_group(%Dependency{type: type, from_issue_id: id}, id)
       when type in [:relates_to, :conflicts_with],
       do: {type, :outbound}

  defp classify_group(%Dependency{type: type, to_issue_id: id}, id)
       when type in [:relates_to, :conflicts_with],
       do: {type, :inbound}

  defp other_endpoint(%Dependency{from_issue_id: id, to_issue_id: other}, id), do: other
  defp other_endpoint(%Dependency{from_issue_id: other}, _id), do: other

  defp load_other_endpoints(edges, issue_id) do
    ids =
      edges
      |> Enum.map(&other_endpoint(&1, issue_id))
      |> Enum.uniq()

    Issue
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  end
end
