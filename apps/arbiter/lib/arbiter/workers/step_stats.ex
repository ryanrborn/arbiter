defmodule Arbiter.Workers.StepStats do
  @moduledoc """
  Roll `worker_run_steps` up into the question the observability issue was
  opened to make cheap: **which tool fails most, on which repo, under which
  resolved skill set** (bd-apwfmy, Definition of done item 3).

  Before the typed step rows existed this was a transcript-mining exercise —
  grep every `⏴ tool error` display line out of a 28 MB corpus and hope the
  rendering never changed. It is now one `GROUP BY`.

  `tool_outcomes/1` is deliberately a single SQL statement rather than several
  round trips stitched in Elixir: the whole point of the phase is that the
  next intra-run question is a query, and a query someone can copy out of this
  module and paste into `sqlite3` is worth more than a private pipeline.

  ## The cells

  A cell is `{tool, repo, skill_set}`. `skill_set` is the run's
  `resolved_skills` provenance flattened to a sorted, comma-joined list of
  skill names — the same provenance that pins `skill_version` at dispatch, so
  a later edit to a skill body cannot retroactively move a historical run into
  another cell. Runs with no provenance (they predate it, or none applied)
  report `""` rather than being dropped.

  ## Honest nulls

  `duration_ms` is nil on any step whose `tool_use` was never seen and on
  every row a Phase 2 backfill wrote from a session JSONL with no per-line
  timestamps. Those rows still count towards `calls` and `errors` — they are
  real calls — but are excluded from `timed_calls` and from the percentiles,
  which are `nil` for a cell with no timed rows. Silently treating a missing
  duration as `0` would be the kind of quiet lie this whole issue exists to
  remove.
  """

  alias Arbiter.Repo

  @type cell :: %{
          tool: String.t(),
          repo: String.t(),
          skill_set: String.t(),
          calls: non_neg_integer(),
          errors: non_neg_integer(),
          error_rate: float(),
          timed_calls: non_neg_integer(),
          p50_ms: non_neg_integer() | nil,
          p95_ms: non_neg_integer() | nil
        }

  # One statement. `steps` narrows and denormalises; `ranked` numbers each
  # cell's timed rows by duration so the percentiles are plain MIN lookups
  # over a rank threshold (SQLite has no percentile_cont).
  @sql """
  WITH steps AS (
    SELECT s.name AS tool,
           r.repo AS repo,
           COALESCE(
             (SELECT group_concat(name)
                FROM (SELECT json_extract(je.value, '$.name') AS name
                        FROM json_each(COALESCE(r.resolved_skills, '[]')) je
                       ORDER BY 1)),
             ''
           ) AS skill_set,
           s.is_error AS is_error,
           s.duration_ms AS duration_ms
      FROM worker_run_steps s
      JOIN worker_runs r ON r.id = s.run_id
     WHERE s.name IS NOT NULL
       AND (?1 IS NULL OR s.occurred_at >= ?1)
       AND (?2 IS NULL OR s.occurred_at <  ?2)
       AND (?3 IS NULL OR r.repo = ?3)
  ),
  ranked AS (
    SELECT tool, repo, skill_set, duration_ms,
           ROW_NUMBER() OVER (PARTITION BY tool, repo, skill_set ORDER BY duration_ms) AS rn,
           COUNT(*)     OVER (PARTITION BY tool, repo, skill_set)                      AS dn
      FROM steps
     WHERE duration_ms IS NOT NULL
  )
  SELECT tool,
         repo,
         skill_set,
         COUNT(*)                                        AS calls,
         SUM(CASE WHEN is_error THEN 1 ELSE 0 END)       AS errors,
         SUM(CASE WHEN duration_ms IS NULL THEN 0 ELSE 1 END) AS timed_calls,
         (SELECT MIN(k.duration_ms) FROM ranked k
           WHERE k.tool = steps.tool AND k.repo = steps.repo
             AND k.skill_set = steps.skill_set
             AND k.rn >= (k.dn + 1) / 2)                 AS p50_ms,
         (SELECT MIN(k.duration_ms) FROM ranked k
           WHERE k.tool = steps.tool AND k.repo = steps.repo
             AND k.skill_set = steps.skill_set
             AND k.rn >= (k.dn * 95 + 99) / 100)         AS p95_ms
    FROM steps
   GROUP BY tool, repo, skill_set
   ORDER BY errors DESC, calls DESC, tool ASC, repo ASC
  """

  @doc """
  Tool outcome cells, worst-first (most errors, then most calls).

  ## Options

    * `:since` / `:until` — `DateTime` bounds on `occurred_at`. Both optional;
      omitting them scans every recorded step.
    * `:repo` — restrict to one repo.
    * `:limit` — cap the number of cells returned (applied after the
      worst-first sort, so the head of the list is what you want to report).

  Steps whose `run_id` no longer resolves to a `worker_runs` row are dropped:
  the join is what supplies `repo` and the skill set, and a cell with neither
  is not the question this function answers.
  """
  @spec tool_outcomes(keyword()) :: [cell()]
  def tool_outcomes(opts \\ []) do
    params = [
      iso(Keyword.get(opts, :since)),
      iso(Keyword.get(opts, :until)),
      Keyword.get(opts, :repo)
    ]

    %{columns: cols, rows: rows} = Repo.query!(@sql, params)

    rows
    |> Enum.map(fn row -> cols |> Enum.zip(row) |> Map.new() |> to_cell() end)
    |> maybe_limit(Keyword.get(opts, :limit))
  end

  @doc """
  The exact SQL `tool_outcomes/1` runs, for pasting into `sqlite3` or an issue.
  Takes three positional parameters: `since`, `until`, `repo` (any may be NULL).
  """
  @spec sql() :: String.t()
  def sql, do: @sql

  defp to_cell(r) do
    calls = int(r["calls"])
    errors = int(r["errors"])

    %{
      tool: r["tool"],
      repo: r["repo"],
      skill_set: r["skill_set"] || "",
      calls: calls,
      errors: errors,
      error_rate: if(calls == 0, do: 0.0, else: errors / calls),
      timed_calls: int(r["timed_calls"]),
      p50_ms: nilable_int(r["p50_ms"]),
      p95_ms: nilable_int(r["p95_ms"])
    }
  end

  defp maybe_limit(cells, n) when is_integer(n) and n > 0, do: Enum.take(cells, n)
  defp maybe_limit(cells, _n), do: cells

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp int(nil), do: 0
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)

  defp nilable_int(nil), do: nil
  defp nilable_int(n) when is_integer(n), do: n
  defp nilable_int(n) when is_float(n), do: trunc(n)
end
