defmodule Arbiter.Loop.Corpus do
  @moduledoc """
  The read layer for the Stage 1 loop-analysis pass (bd-dyfaq3, epic #1011):
  fetch one window of the loop's own telemetry as enriched
  `worker_runs`, and record the pass's own cost.

  `fetch/1` joins `worker_runs ⨝ usage_events ⨝ review_gate_rounds ⨝ issues`
  for a window and returns one row per `worker_run`, enriched with its work
  cost, max review round, reviewer findings, the issue's dispatched difficulty,
  and — **only for failed runs** — the bounded *tail* of its transcript
  (`Arbiter.Worker.OutputLog.tail_lines/2`). `Arbiter.Loop.Analysis.build_report/2`
  reasons over those rows purely.

  ## Read discipline (this is the module the crashed first attempt lacked)

  Everything here is a **bounded aggregate**: grouped counts and sums keyed by
  run/task, never `SELECT *` over a 400-row table, and transcript reads are
  bounded per failed run. That is deliberate — attempt 1 at this task
  (`c88c77b0`) died of context exhaustion from unbounded reads. The whole point
  of doing the fetch in Elixir is that the operator's context never sees the
  raw corpus, only the shaped report.

  ## Structured first, transcript only as fallback (bd-apwfmy)

  A failed run whose typed `stop_category` already decides its classification
  (see `Arbiter.Loop.FailureClassifier.conclusive_stop_categories/0`) gets **no
  transcript read at all** — `terminal_lines` stays `[]` and the classifier
  works off the column. Only runs with no category, or an inconclusive one
  (`:crashed`, `:stalled`), fall back to the bounded read below. `meta`
  reports `failed_runs` and `transcript_reads` so a window says out loud how
  much of itself still had to be text-mined.

  `transcript_reads` counts the *fallback decision*, carried on each row as
  `transcript_read?` — not the reads that happened to return lines. A run
  whose output log was reaped still had to fall back; scoring it as zero
  reads would report a blind window as a fully-structured one.

  A fallback run's `terminal_lines` is the union of two bounded reads
  (`OutputLog.tail_lines/2` + `OutputLog.scan_for/2`), not a raw transcript
  read — see bd-3ozmaj (#1159) and the "bounded scan" note in
  `docs/loop-review.md`:

    * the last `@tail_n` (40) lines — the terminal signal (autocompact
      thrash, `claude session error`, final `arb done`).
    * every line matching `FailureClassifier.infra_fingerprints/0` — narrow,
      unambiguous infra fingerprints (`Phoenix.Ecto.PendingMigrationError`,
      `DBConnection.ConnectionError`) that can appear anywhere in the
      transcript, not just its tail, because the agent typically keeps going
      after the failure. This scan reads the whole file but returns only the
      (typically zero or one) matching lines — safe because the fingerprint
      list is narrow enough to carry no false-positive risk, and the corpus
      is small (tens of files, single-digit MB).

  ## Quota-window enrichment (#1463, Amendment E)

  Each row also carries `weighted_tokens` — its draw on the binding 5-hour
  utilization window — and `window_share_5h`, that draw as a fraction of one
  window's calibrated capacity. `meta.scarcity` carries the calibration, the
  installation's billing mode, and which unit the pass is therefore optimising.
  `Arbiter.Loop.Scarcity` owns the unit definition and the reasoning behind it;
  this module only supplies the two bounded reads it needs (per-run token sums
  over the corpus window, and the workspace's total weighted draw over the
  *current* 5h window, which is what the provider's `utilization_5h` reading
  can be divided into).

  A `window_share_5h` of `nil` means the window could not be calibrated —
  never "this run drew nothing". `meta.scarcity.calibration.reason` says which
  of the three absences it was, the same way `transcript_reads` refuses to
  report a blind window as a fully-structured one.

  ## The one write

  `record_pass_cost/1` inserts a single `Arbiter.Usage.Event` row (step
  `:other`, task `loop-analyze`) so the loop's own cost lands in the ledger it
  is optimising. It is the **only** write the pass performs — no skills, no
  config, no issue overrides.
  """

  require Logger

  alias Arbiter.Loop.FailureClassifier
  alias Arbiter.Loop.Scarcity
  alias Arbiter.Quota
  alias Arbiter.Quota.Overage
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.OutputLog

  @tail_n 40
  @pass_task_id "loop-analyze"

  @type row :: map()
  @type meta :: %{
          label: String.t(),
          since: DateTime.t(),
          until: DateTime.t(),
          workspace_id: term(),
          failed_runs: non_neg_integer(),
          transcript_reads: non_neg_integer(),
          scarcity: scarcity()
        }

  @type scarcity :: %{
          unit: :window_share_5h | :cost_usd,
          secondary_unit: :window_share_5h | :cost_usd,
          billing_mode: Scarcity.billing_mode(),
          calibration: Scarcity.calibration()
        }

  @doc """
  Fetch the window. Options: `:since`, `:until` (`DateTime`s — default: last 7
  days), `:label`, `:limit` (cap on runs scanned, newest first), `:workspace_id`.
  Returns `{:ok, rows, meta}`.
  """
  @spec fetch(keyword()) :: {:ok, [row()], meta()}
  def fetch(opts \\ []) do
    until = Keyword.get(opts, :until) || DateTime.utc_now()
    since = Keyword.get(opts, :since) || DateTime.add(until, -7 * 24 * 3600, :second)
    days = max(1, div(DateTime.diff(until, since, :second), 24 * 3600))
    label = Keyword.get(opts, :label) || "last #{days}d"
    limit = Keyword.get(opts, :limit)

    runs = base_runs(since, until, limit)
    cost_by_run = cost_by_run(since, until)
    tokens_by_run = tokens_by_run(since, until)
    scarcity = scarcity(Keyword.get(opts, :workspace_id))
    # Review activity is task-scoped: rounds and reviewer findings are recorded
    # under the reviewer's run and a `#review`-suffixed task_id, so they must be
    # keyed by the BASE task id — never the main run_id, which never appears in
    # review_gate_rounds.
    round_by_task = max_round_by_task()
    findings_by_task = findings_by_task()

    base_ids = runs |> Enum.map(&base_task_id(&1["task_id"])) |> Enum.uniq()
    difficulty_by_task = difficulty_by_task(base_ids)

    rows =
      Enum.map(runs, fn r ->
        run_id = r["run_id"]
        task_id = r["task_id"]
        base = base_task_id(task_id)
        status = to_atom(r["status"])
        {read?, lines} = terminal_lines(status, r["stop_category"], run_id)
        weighted = Map.get(tokens_by_run, run_id, 0.0)

        %{
          run_id: run_id,
          task_id: task_id,
          repo: r["repo"],
          title: r["task_title"],
          worker_type: to_atom(r["worker_type"]),
          status: status,
          model: r["model"],
          model_tier: nil,
          difficulty: Map.get(difficulty_by_task, base),
          difficulty_source: :issue,
          failure_reason: r["failure_reason"],
          stop_category: r["stop_category"],
          cost_usd: Map.get(cost_by_run, run_id, 0.0),
          weighted_tokens: weighted,
          window_share_5h: Scarcity.window_share(weighted, scarcity.calibration),
          max_round: Map.get(round_by_task, base, 1),
          rejected?: r["failure_reason"] == ":review_gate_rejected",
          converged?: status == :completed,
          findings: Map.get(findings_by_task, base, []),
          transcript_read?: read?,
          terminal_lines: lines
        }
      end)

    failed = Enum.count(rows, &(&1.status == :failed))
    reads = Enum.count(rows, & &1.transcript_read?)

    meta = %{
      label: label,
      since: since,
      until: until,
      workspace_id: Keyword.get(opts, :workspace_id),
      failed_runs: failed,
      transcript_reads: reads,
      scarcity: scarcity
    }

    {:ok, rows, meta}
  end

  @doc """
  True when a run's typed `stop_category` decides its classification on its
  own, so the transcript never needs opening. Delegates the list of
  conclusive categories to `Arbiter.Loop.FailureClassifier` rather than
  keeping a second copy here.
  """
  @spec conclusive_stop_category?(String.t() | nil) :: boolean()
  def conclusive_stop_category?(nil), do: false

  def conclusive_stop_category?(category) when is_binary(category) do
    FailureClassifier.conclusive_stop_categories()
    |> Enum.any?(fn {known, _verdict} -> Atom.to_string(known) == category end)
  end

  def conclusive_stop_category?(_other), do: false

  # Only a failed run with no conclusive typed category costs a transcript
  # read. Returns `{read_attempted?, lines}` — the flag, not the lines, is what
  # `meta.transcript_reads` counts. A reaped output log yields no lines but the
  # run still fell back to text-mining, and a window reporting that as zero
  # reads would be indistinguishable from one with full structured coverage.
  defp terminal_lines(:failed, stop_category, run_id) do
    if conclusive_stop_category?(stop_category), do: {false, []}, else: {true, tail(run_id)}
  end

  defp terminal_lines(_status, _stop_category, _run_id), do: {false, []}

  @doc """
  Record the pass's own cost as a single `usage_events` row (step `:other`,
  task `#{@pass_task_id}`). Returns the new row id, or `nil` if the insert
  failed (the pass never crashes on a ledger hiccup). This is the pass's only
  write.
  """
  @spec record_pass_cost(map()) :: String.t() | nil
  def record_pass_cost(%{} = info) do
    attrs = %{
      task_id: @pass_task_id,
      workspace_id: Map.get(info, :workspace_id),
      step: :other,
      model: "loop-analysis-pass",
      provider: "arbiter",
      cost_usd: Map.get(info, :cost_usd, 0.0),
      # #1463: the pass's own draw on the quota windows it now measures. Stage 1
      # analysis is deterministic Elixir — it makes no model call — so the draw
      # is a *measured* zero, written explicitly rather than left `nil`. If the
      # payload-authoring work ever puts an LLM call inside `Loop`, these
      # columns are where its draw lands, and the report's own-draw note stops
      # being able to say "none".
      tokens_in: Map.get(info, :tokens_in, 0),
      tokens_out: Map.get(info, :tokens_out, 0),
      cache_creation_tokens: Map.get(info, :cache_creation_tokens, 0),
      cache_read_tokens: Map.get(info, :cache_read_tokens, 0),
      duration_ms: Map.get(info, :duration_ms),
      occurred_at: DateTime.utc_now(),
      worker_run_id: nil,
      raw: %{
        kind: "loop_analysis_pass",
        rows_scanned: Map.get(info, :rows_scanned),
        quota_window_draw: "none"
      }
    }

    case Ash.create(Arbiter.Usage.Event, attrs) do
      {:ok, row} ->
        row.id

      {:error, reason} ->
        Logger.warning("Loop.Corpus.record_pass_cost/1 swallowed: #{inspect(reason)}")
        nil
    end
  end

  # ---- bounded queries ----------------------------------------------------

  defp base_runs(since, until, limit) do
    limit_clause = if is_integer(limit) and limit > 0, do: "LIMIT #{limit}", else: ""

    query(
      """
      SELECT id AS run_id, task_id, repo, task_title, worker_type, status, model,
             failure_reason, stop_category
      FROM worker_runs
      WHERE started_at >= ?1 AND started_at < ?2
      ORDER BY started_at DESC
      #{limit_clause}
      """,
      [iso(since), iso(until)]
    )
  end

  defp cost_by_run(since, until) do
    query(
      """
      SELECT worker_run_id AS run_id, SUM(cost_usd) AS cost
      FROM usage_events
      WHERE worker_run_id IS NOT NULL AND occurred_at >= ?1 AND occurred_at < ?2
      GROUP BY worker_run_id
      """,
      [iso(since), iso(until)]
    )
    |> Map.new(fn r -> {r["run_id"], flt(r["cost"])} end)
  end

  # Per-run weighted token draw over the corpus window — the numerator of
  # `window_share_5h`. Grouped in SQL like `cost_by_run/2`; the weighting is
  # applied in Elixir so `Arbiter.Loop.Scarcity` stays the single place the
  # weight vector is defined.
  defp tokens_by_run(since, until) do
    query(
      """
      SELECT worker_run_id AS run_id,
             SUM(COALESCE(tokens_in, 0)) AS tokens_in,
             SUM(COALESCE(tokens_out, 0)) AS tokens_out,
             SUM(COALESCE(cache_creation_tokens, 0)) AS cache_creation_tokens,
             SUM(COALESCE(cache_read_tokens, 0)) AS cache_read_tokens
      FROM usage_events
      WHERE worker_run_id IS NOT NULL AND occurred_at >= ?1 AND occurred_at < ?2
      GROUP BY worker_run_id
      """,
      [iso(since), iso(until)]
    )
    |> Map.new(fn r -> {r["run_id"], Scarcity.weighted_tokens(r)} end)
  end

  # The scarcity frame for this pass: which unit binds, how we know, and the
  # 5h-window capacity every per-run share is divided by.
  #
  # Calibration deliberately reads the **current** 5h window, not the corpus
  # window: `anthropic_quotas` is a latest-only cache, so the only utilization
  # figure that exists is `now`'s, and it can only be divided into the draw of
  # the window it was measured over. Capacity is a plan constant, so the
  # estimate carries across the corpus window; the estimate's own inputs are
  # reported (`observed_weighted_tokens`, `utilization`, `captured_at`) so an
  # operator can see how it was derived.
  #
  # Fail-soft throughout: any read error degrades to an uncalibrated frame
  # rather than crashing the pass, exactly as `record_pass_cost/1` swallows a
  # ledger hiccup.
  defp scarcity(workspace_id) do
    ws_id = resolve_workspace_id(workspace_id)
    snapshot = ws_id && Quota.latest(ws_id, "claude")
    config = ws_id && workspace_config(ws_id)

    since = Overage.window_start(snapshot)
    observed = if ws_id, do: weighted_tokens_since(ws_id, since), else: 0.0

    calibration = Scarcity.calibrate(observed, snapshot, since: since)
    mode = Scarcity.billing_mode(config, snapshot)

    %{
      unit: Scarcity.primary_metric(mode),
      secondary_unit: Scarcity.secondary_metric(mode),
      billing_mode: mode,
      calibration: calibration
    }
  rescue
    error ->
      Logger.warning("Loop.Corpus.scarcity/1 degraded to uncalibrated: #{inspect(error)}")

      mode = {:metered, :default}

      %{
        unit: Scarcity.primary_metric(mode),
        secondary_unit: Scarcity.secondary_metric(mode),
        billing_mode: mode,
        calibration: Scarcity.calibrate(0.0, nil)
      }
  end

  defp resolve_workspace_id(id) when is_binary(id) and id != "", do: id

  defp resolve_workspace_id(_) do
    case Quota.default_workspace_id() do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The workspace's total weighted draw since the current 5h window opened —
  # the denominator side of the calibration. One grouped row, never a scan of
  # individual events.
  defp weighted_tokens_since(ws_id, %DateTime{} = since) do
    query(
      """
      SELECT SUM(COALESCE(tokens_in, 0)) AS tokens_in,
             SUM(COALESCE(tokens_out, 0)) AS tokens_out,
             SUM(COALESCE(cache_creation_tokens, 0)) AS cache_creation_tokens,
             SUM(COALESCE(cache_read_tokens, 0)) AS cache_read_tokens
      FROM usage_events
      WHERE workspace_id = ?1 AND occurred_at >= ?2
      """,
      [ws_id, iso(since)]
    )
    |> case do
      [row] -> Scarcity.weighted_tokens(row)
      _ -> 0.0
    end
  end

  defp max_round_by_task do
    query("SELECT task_id, MAX(round) AS max_round FROM review_gate_rounds GROUP BY task_id", [])
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.reduce(%{}, fn r, acc ->
      base = base_task_id(r["task_id"])
      Map.update(acc, base, int(r["max_round"]), &max(&1, int(r["max_round"])))
    end)
  end

  # Reviewer findings text, split into individual finding items for clustering,
  # keyed by base task id (review rows carry a `#review`-suffixed task_id).
  defp findings_by_task do
    query(
      """
      SELECT task_id, findings
      FROM review_gate_rounds
      WHERE role = 'review' AND findings IS NOT NULL AND findings <> ''
      """,
      []
    )
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.group_by(&base_task_id(&1["task_id"]))
    |> Map.new(fn {base, rows} ->
      items = rows |> Enum.flat_map(fn r -> split_findings(r["findings"]) end)
      {base, items}
    end)
  end

  # Strip the ReviewGate `#review…`/`#impl…` suffix to get the authoring task id.
  defp base_task_id(nil), do: nil
  defp base_task_id(task_id), do: task_id |> String.split("#") |> hd()

  # Split a reviewer's free-text findings block into individual finding lines.
  # Numbered items ("1. ...", "**[High] ...") are the finding units; a block
  # with none collapses to a single element so it is still clusterable.
  defp split_findings(text) when is_binary(text) do
    items =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&finding_line?/1)

    if items == [], do: [text], else: items
  end

  defp split_findings(_), do: []

  defp finding_line?(line) do
    Regex.match?(~r/^\d+\.\s/, line) or Regex.match?(~r/^\*\*\[/, line) or
      Regex.match?(~r/^-\s+\*\*/, line)
  end

  defp difficulty_by_task([]), do: %{}

  defp difficulty_by_task(task_ids) do
    placeholders = task_ids |> Enum.with_index(1) |> Enum.map(fn {_id, i} -> "?#{i}" end)

    query(
      "SELECT id, difficulty FROM issues WHERE id IN (#{Enum.join(placeholders, ",")})",
      task_ids
    )
    |> Enum.reject(&is_nil(&1["difficulty"]))
    |> Map.new(fn r -> {r["id"], int(r["difficulty"])} end)
  end

  defp tail(run_id) do
    tail_lines =
      case OutputLog.tail_lines(run_id, @tail_n) do
        {:ok, lines} -> lines
        {:error, _} -> []
      end

    infra_lines =
      case OutputLog.scan_for(run_id, FailureClassifier.infra_fingerprints()) do
        {:ok, lines} -> lines
        {:error, _} -> []
      end

    Enum.uniq(tail_lines ++ infra_lines)
  end

  # ---- helpers ------------------------------------------------------------

  # As in Loop.Canary.Metrics: the interpolated text is a generated `?N`
  # placeholder list, never a value. Values travel in `params`.
  # sobelow_skip ["SQL.Query"]
  defp query(sql, params) do
    %{columns: cols, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end

  # Column values out of Arbiter's own tables — statuses and worker types that
  # Ash dumped from atoms it defined. `String.to_existing_atom/1` rather than
  # `String.to_atom/1` (sobelow DOS.StringToAtom): a row carrying an
  # unrecognised string is corrupt data, and minting a permanent atom for it
  # is the worse of the two failure modes.
  defp to_atom(nil), do: nil
  defp to_atom(a) when is_atom(a), do: a

  defp to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp int(nil), do: 0
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(n) when is_binary(n), do: String.to_integer(n)

  defp flt(nil), do: 0.0
  defp flt(n) when is_number(n), do: n / 1
end
