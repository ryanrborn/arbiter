defmodule Arbiter.Usage do
  @moduledoc """
  Ash domain + aggregation API for the structured token/cost usage ledger.

  Every Claude session — work worker or Tribunal reviewer — emits a final
  `result` event carrying tokens (input / output / cache), `total_cost_usd`,
  `duration_ms`, and model. The polecat captures that and inserts an
  `Arbiter.Usage.Event` row keyed by bead + step (`:work | :review`) +
  optional `workspace_id` and `polecat_run_id` for joinability.

  Multiple rows per bead are deliberate: a re-slung bead writes a second
  `:work` row, a Tribunal review adds a `:review` row, etc. Rework is then
  visible as the spend across rows for the same bead.

  ## Aggregation

  `summarize/1` rolls events up by one of `:day`, `:bead`, `:campaign`
  (parent/epic), `:workspace`, `:rig`, `:model`, or `:step`. It returns a list
  of maps with `{group:, total_cost_usd:, tokens_in:, tokens_out:, ...}`.

  The CLI (`arb usage`) and Phoenix endpoint (`GET /api/usage`) sit on top of
  this. Anything new (per-day burn dashboards, budget routing) should call
  `summarize/1` rather than re-doing SQL.
  """

  use Ash.Domain

  alias Arbiter.Beads.Dependency
  alias Arbiter.Usage.Event
  require Ash.Query

  resources do
    resource Arbiter.Usage.Event
  end

  @type group_by ::
          :day | :bead | :campaign | :workspace | :rig | :model | :step | :provider

  @type since :: DateTime.t() | nil

  @type rollup :: %{
          required(:group) => term(),
          required(:rows) => non_neg_integer(),
          required(:total_cost_usd) => float(),
          required(:tokens_in) => non_neg_integer(),
          required(:tokens_out) => non_neg_integer(),
          required(:cache_creation_tokens) => non_neg_integer(),
          required(:cache_read_tokens) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer()
        }

  @valid_by ~w(day bead campaign workspace rig model step provider)a

  @doc """
  Roll up usage events into a list of summary rows.

  ## Options

    * `:by` — one of `#{inspect(@valid_by)}`. Required.
    * `:since` — `%DateTime{}` filter on `occurred_at`. Optional.
    * `:workspace_id` — restrict to one workspace. Optional.
    * `:limit` — cap the returned rows (after sort). Optional.

  Returns `{:ok, [rollup]}` or `{:error, reason}`. Rows are sorted by
  `total_cost_usd` desc (or chronologically for `:by :day`).

  `:campaign` groups by a bead's `:parent_of` parent(s) — a bead with more than
  one parent is counted in each, mirroring the parent-with-progress rollup.
  Beads with *no* parent don't disappear; they fall into the catch-all sentinel
  `(no_campaign)` so spend isn't silently lost.
  """
  @spec summarize(keyword()) :: {:ok, [rollup()]} | {:error, term()}
  def summarize(opts) when is_list(opts) do
    with {:ok, by} <- fetch_by(opts) do
      events =
        Event
        |> base_filter(opts)
        |> Ash.read!()

      {:ok,
       events
       |> group_events(by)
       |> Enum.map(&aggregate_group(by, &1))
       |> sort_rollups(by)
       |> maybe_limit(opts)}
    end
  end

  @spec valid_groupings() :: [group_by()]
  def valid_groupings, do: @valid_by

  # ---- aggregation -------------------------------------------------------

  defp fetch_by(opts) do
    case Keyword.fetch(opts, :by) do
      {:ok, by} when by in @valid_by -> {:ok, by}
      {:ok, other} -> {:error, {:invalid_grouping, other}}
      :error -> {:error, :missing_grouping}
    end
  end

  defp base_filter(query, opts) do
    query =
      case Keyword.get(opts, :since) do
        nil -> query
        %DateTime{} = dt -> Ash.Query.filter(query, occurred_at >= ^dt)
      end

    case Keyword.get(opts, :workspace_id) do
      nil -> query
      "" -> query
      ws -> Ash.Query.filter(query, workspace_id == ^ws)
    end
  end

  # Group events by the requested dimension. For :campaign we resolve each
  # event's bead's `:parent_of` parents at read time (a join would be cleaner
  # but the data volume is small for now; this is plain in-memory grouping).
  defp group_events(events, :day) do
    Enum.group_by(events, fn ev -> Date.to_iso8601(DateTime.to_date(ev.occurred_at)) end)
  end

  defp group_events(events, :bead), do: Enum.group_by(events, & &1.bead_id)

  defp group_events(events, :workspace),
    do: Enum.group_by(events, &(&1.workspace_id || "(none)"))

  defp group_events(events, :rig), do: Enum.group_by(events, &(&1.rig || "(none)"))
  defp group_events(events, :model), do: Enum.group_by(events, &(&1.model || "(unknown)"))
  defp group_events(events, :provider), do: Enum.group_by(events, &(&1.provider || "(unknown)"))
  defp group_events(events, :step), do: Enum.group_by(events, &Atom.to_string(&1.step))

  defp group_events(events, :campaign) do
    parents = load_parent_edges(events)

    Enum.reduce(events, %{}, fn ev, acc ->
      base_bead = base_bead_id(ev.bead_id)

      case Map.get(parents, base_bead, []) do
        [] -> Map.update(acc, "(no_campaign)", [ev], &[ev | &1])
        ids -> Enum.reduce(ids, acc, fn pid, a -> Map.update(a, pid, [ev], &[ev | &1]) end)
      end
    end)
  end

  # Drop the "#review" suffix used by Tribunal reviewers so a review event is
  # still attributable to the author bead for campaign lookup.
  defp base_bead_id(<<id::binary>>) do
    case String.split(id, "#", parts: 2) do
      [base | _] -> base
      _ -> id
    end
  end

  # Map each event's bead to the parent bead(s) it hangs under via `:parent_of`
  # edges (the bead is the `to_issue`; its parents are the `from_issue`s).
  defp load_parent_edges(events) do
    parent_of = :parent_of

    bead_ids =
      events
      |> Enum.map(&base_bead_id(&1.bead_id))
      |> Enum.uniq()

    case bead_ids do
      [] ->
        %{}

      ids ->
        Dependency
        |> Ash.Query.filter(type == ^parent_of and to_issue_id in ^ids)
        |> Ash.read!()
        |> Enum.reduce(%{}, fn d, acc ->
          Map.update(acc, d.to_issue_id, [d.from_issue_id], &[d.from_issue_id | &1])
        end)
    end
  rescue
    _ -> %{}
  end

  defp aggregate_group(_by, {group, events}) do
    init = %{
      group: group,
      rows: 0,
      total_cost_usd: 0.0,
      tokens_in: 0,
      tokens_out: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      duration_ms: 0
    }

    Enum.reduce(events, init, fn ev, acc ->
      %{
        acc
        | rows: acc.rows + 1,
          total_cost_usd: acc.total_cost_usd + (ev.cost_usd || 0.0),
          tokens_in: acc.tokens_in + (ev.tokens_in || 0),
          tokens_out: acc.tokens_out + (ev.tokens_out || 0),
          cache_creation_tokens: acc.cache_creation_tokens + (ev.cache_creation_tokens || 0),
          cache_read_tokens: acc.cache_read_tokens + (ev.cache_read_tokens || 0),
          duration_ms: acc.duration_ms + (ev.duration_ms || 0)
      }
    end)
  end

  defp sort_rollups(rollups, :day), do: Enum.sort_by(rollups, & &1.group)

  defp sort_rollups(rollups, _by),
    do: Enum.sort_by(rollups, &(-(&1.total_cost_usd || 0.0)))

  defp maybe_limit(rollups, opts) do
    case Keyword.get(opts, :limit) do
      n when is_integer(n) and n > 0 -> Enum.take(rollups, n)
      _ -> rollups
    end
  end
end
