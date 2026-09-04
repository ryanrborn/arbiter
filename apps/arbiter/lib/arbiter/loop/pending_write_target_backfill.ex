defmodule Arbiter.Loop.PendingWriteTargetBackfill do
  @moduledoc """
  bd-5w8h0r: one-time re-homing of the finding-category rows written before
  the category → skill attribution table existed.

  ## Why a backfill is forced

  `target` is a **fingerprint input** — `Arbiter.Loop.fingerprint/1` digests
  `{kind, target, category, difficulty, repo}`. Before
  `Arbiter.Loop.FindingBuckets`' attribution table, a finding-category
  proposal was written with `target: nil` and a payload carrying evidence and
  nothing else; now the same category resolves to a named skill and, for two
  of the five, to `:skill_create` rather than `:skill_patch`. Every one of
  those three fields moved, so the identity of the proposal moved with it.

  Left alone, the live pre-table rows would sit at a fingerprint no future
  pass can reach: `Arbiter.Loop.record/2` would open a second, empty row
  beside each one and the accumulated evidence — four and five incidents
  apiece, several windows deep — would stop counting toward the bar. That is
  exactly what `:superseded` exists for (`pending_write.ex:26`), so each old
  row is marked `:superseded` and its `incident_refs` / `task_refs` are
  carried onto its new-fingerprint successor.

  ## The rule

  For every row with `kind = 'skill_patch'`, `target IS NULL` and a live state
  (`:hypothesis` or `:proposed`) whose `category` resolves through the
  attribution table:

    * compute the successor identity and fingerprint via
      `Arbiter.Loop.Proposals.finding_identity/1`;
    * if a live row already stands at that fingerprint — a pass has run since
      the table shipped — **union** the old row's evidence onto it and
      re-render its payload, rather than opening a duplicate the partial
      unique index would refuse anyway;
    * otherwise insert the successor, carrying the evidence refs and counts,
      the state, the workspace, the origin and `escalated_at` (so the
      exactly-once promotion escalation is not re-posted for evidence an
      operator has already been told about);
    * either way, mark the old row `:superseded`.

  Three deliberate non-actions:

    * **`:rejected` rows are left alone.** A rejection is a record of a human
      decision about a specific proposal; the successor is a materially
      different one, and the old row is neither live nor orphaned. It also
      falls outside the `(fingerprint, state)` partial unique index, so it
      blocks nothing.
    * **A category with no attribution row is left live and counted
      `unresolved`.** Guessing a target would be worse than the gap `Apply`
      already reports. `FindingBuckets`' compile-time guard means the analyser
      cannot produce one; a row like this is hand-built or predates a category
      rename.
    * **`created_at` is carried, not reset.** The finding's age is real, and
      resetting it would make a months-old proposal read as new in
      `arb loop pending`.

  ## Plain SQL, on purpose

  Same reason as `Arbiter.Loop.PendingWriteWorkspaceBackfill`: this runs from
  inside an `Ecto.Migration`, where under `bin/arbiter eval
  Arbiter.Release.migrate` only `Ecto.Migrator.with_repo/2` runs — the repo is
  started, the OTP application and Ash are not. The rendering helpers it calls
  (`Arbiter.Loop.Proposals.finding_identity/1`, `finding_payload/2`,
  `finding_gist/1`, `Arbiter.Loop.fingerprint/1`,
  `Arbiter.Loop.estimate_tokens/1`) are pure module functions with no process
  behind them, so they are safe from that context; anything reading through
  `Ash` would not be.

  A consequence worth naming: the successor is inserted with a raw `INSERT`,
  so it gets no AshPaperTrail version row. The audit trail for the move is
  this migration plus the superseded original, which keeps its own history.
  """

  alias Arbiter.Loop
  alias Arbiter.Loop.{FindingBuckets, Proposals}
  alias Arbiter.Repo

  @actor "loop:backfill:bd-5w8h0r"

  @type report :: %{
          examined: non_neg_integer(),
          superseded: non_neg_integer(),
          inserted: non_neg_integer(),
          merged: non_neg_integer(),
          unresolved: non_neg_integer()
        }

  @doc """
  Re-home every live `target: nil` finding row. Idempotent: a second run finds
  nothing to examine, because the rows it moved are no longer live and the
  successors it wrote all carry a target.
  """
  @spec run() :: report()
  def run do
    rows = live_targetless_rows()

    Enum.reduce(
      rows,
      %{examined: length(rows), superseded: 0, inserted: 0, merged: 0, unresolved: 0},
      &rehome/2
    )
  end

  # ---- one row -------------------------------------------------------------

  defp rehome(row, report) do
    case FindingBuckets.attribution(row.category) do
      nil ->
        %{report | unresolved: report.unresolved + 1}

      _attribution ->
        identity = Proposals.finding_identity(row.category)
        fingerprint = Loop.fingerprint(identity)

        outcome =
          case live_row_at(fingerprint) do
            nil -> insert_successor(row, identity, fingerprint)
            successor -> merge_into(successor, row, identity)
          end

        supersede(row.id)

        report
        |> Map.update!(:superseded, &(&1 + 1))
        |> Map.update!(outcome, &(&1 + 1))
    end
  end

  defp insert_successor(row, identity, fingerprint) do
    payload =
      Proposals.finding_payload(identity, %{
        example: row.example,
        incidents: row.evidence_count,
        tasks: row.task_refs,
        destination: row.destination,
        window_until: row.window_until
      })

    gist = Proposals.finding_gist(row.category)

    Repo.query!(
      """
      INSERT INTO loop_pending_writes
        (id, kind, gist, payload, target_metric, baseline, context_cost_tokens,
         evidence_count, distinct_tasks, incident_refs, task_refs, scope, state,
         fingerprint, category, target, origin, escalated_at, actor, workspace_id,
         created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Ash.UUIDv7.generate(),
        to_string(identity.kind),
        gist,
        Jason.encode!(payload),
        row.target_metric,
        row.baseline,
        price(payload, gist),
        row.evidence_count,
        row.distinct_tasks,
        Jason.encode!(row.incident_refs),
        Jason.encode!(row.task_refs),
        row.scope,
        row.state,
        fingerprint,
        row.category,
        identity.target,
        row.origin,
        row.escalated_at,
        @actor,
        row.workspace_id,
        row.created_at,
        now()
      ]
    )

    :inserted
  end

  defp merge_into(successor, row, identity) do
    incident_refs = union(successor.incident_refs, row.incident_refs)
    task_refs = union(successor.task_refs, row.task_refs)

    payload =
      Proposals.finding_payload(identity, %{
        example: successor.example || row.example,
        incidents: length(incident_refs),
        tasks: task_refs,
        destination: successor.destination || row.destination,
        window_until: later(successor.window_until, row.window_until)
      })

    gist = Proposals.finding_gist(row.category)

    Repo.query!(
      """
      UPDATE loop_pending_writes
      SET incident_refs = ?, task_refs = ?, evidence_count = ?, distinct_tasks = ?,
          state = ?, payload = ?, gist = ?, context_cost_tokens = ?,
          escalated_at = COALESCE(escalated_at, ?), actor = ?, updated_at = ?
      WHERE id = ?
      """,
      [
        Jason.encode!(incident_refs),
        Jason.encode!(task_refs),
        length(incident_refs),
        length(task_refs),
        # Evidence only ever grows, so a row that already cleared the bar
        # cannot un-clear it: :proposed wins over :hypothesis. Re-evaluating
        # the bar properly would need the workspace's config, which means Ash.
        promoted_state(successor.state, row.state),
        Jason.encode!(payload),
        gist,
        price(payload, gist),
        row.escalated_at,
        @actor,
        now()
      ] ++ [successor.id]
    )

    :merged
  end

  defp supersede(id) do
    Repo.query!(
      "UPDATE loop_pending_writes SET state = 'superseded', actor = ?, updated_at = ? WHERE id = ?",
      [@actor, now(), id]
    )
  end

  # ---- reading -------------------------------------------------------------

  @select """
  SELECT id, category, payload, incident_refs, task_refs, evidence_count,
         distinct_tasks, scope, state, target_metric, baseline, origin,
         workspace_id, escalated_at, created_at, updated_at
  FROM loop_pending_writes
  """

  defp live_targetless_rows do
    %{rows: rows} =
      Repo.query!(
        @select <>
          """
          WHERE kind = 'skill_patch'
          AND target IS NULL
          AND category IS NOT NULL
          AND state IN ('hypothesis', 'proposed')
          ORDER BY created_at
          """,
        []
      )

    Enum.map(rows, &decode/1)
  end

  defp live_row_at(fingerprint) do
    %{rows: rows} =
      Repo.query!(
        @select <> "WHERE fingerprint = ? AND state IN ('hypothesis', 'proposed') LIMIT 1",
        [fingerprint]
      )

    case rows do
      [row] -> decode(row)
      [] -> nil
    end
  end

  defp decode([
         id,
         category,
         payload,
         incident_refs,
         task_refs,
         evidence_count,
         distinct_tasks,
         scope,
         state,
         target_metric,
         baseline,
         origin,
         workspace_id,
         escalated_at,
         created_at,
         updated_at
       ]) do
    payload = decode_json(payload, %{})

    %{
      id: id,
      category: category,
      payload: payload,
      # The window the clause cites is the last one that touched this row —
      # the payload is re-rendered on every reinforcement, so `updated_at` is
      # the window date the original provenance comment would have carried.
      window_until: to_date(updated_at),
      example: Map.get(payload, "example"),
      destination: Map.get(payload, "destination"),
      incident_refs: decode_json(incident_refs, []),
      task_refs: decode_json(task_refs, []),
      evidence_count: evidence_count || 0,
      distinct_tasks: distinct_tasks || 0,
      scope: scope,
      state: state,
      target_metric: target_metric,
      baseline: baseline,
      origin: origin,
      workspace_id: workspace_id,
      escalated_at: escalated_at,
      created_at: created_at
    }
  end

  # ---- small helpers -------------------------------------------------------

  defp decode_json(nil, default), do: default

  defp decode_json(text, default) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _} -> default
    end
  end

  defp decode_json(other, _default), do: other

  defp union(a, b), do: (a ++ b) |> Enum.uniq() |> Enum.sort()

  defp promoted_state(a, b) when "proposed" in [a, b], do: "proposed"
  defp promoted_state(a, _b), do: a

  defp price(payload, gist) do
    case Map.get(payload, "clause") do
      clause when is_binary(clause) and clause != "" -> Loop.estimate_tokens(clause)
      _ -> Loop.estimate_tokens(gist)
    end
  end

  defp to_date(iso) when is_binary(iso) do
    case iso |> String.slice(0, 10) |> Date.from_iso8601() do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt)
  defp to_date(_), do: nil

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
