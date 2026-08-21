defmodule Arbiter.Workers.StepBackfill do
  @moduledoc """
  Reconstruct typed `Arbiter.Workers.RunStep` rows for runs that finished
  before live step capture existed (bd-apwfmy, Phase 2).

  Live capture only ever sees the future. Every run already in the corpus has
  its tool calls sitting on disk in Claude Code's own session JSONL at
  `<config_dir>/projects/<slug>/<session_id>.jsonl` — the same file
  `Arbiter.Usage.ClaudeSessionFile` already reads for token totals. That file
  is the only retroactive source of ground truth: the rendered transcript has
  thrown the structure away, which is the whole complaint the parent issue
  opens with.

  ## Properties this has to hold

    * **Idempotent.** "Run the backfill again" is what anyone does when they
      are not sure it finished. A pass skips every `tool_use_id` already
      stored for the run — including ones the live path wrote — so re-running
      converges instead of doubling.
    * **Dry by default.** `backfill/1` and `backfill_run/2` report what they
      *would* insert unless passed `apply?: true`, matching
      `mix arbiter.backfill_task_statuses`.
    * **Honest gaps.** A run with no `session_id`, or whose session file has
      been reaped, is *counted* — not silently skipped and not an error. A
      report that says "412 runs, 38 with no session file" is usable; one
      that says "412 runs" is not.
    * **Same redaction choke-point.** Summaries go through
      `Arbiter.Worker.StepSummary`, exactly as the live emit path does. See
      that module for why there is no second summarizer.

  ## What a backfilled row is *not*

  `duration_ms` comes from the difference between two line timestamps, not a
  monotonic clock, and is nil when either line was undated. An undated call
  is dropped rather than guessed into this run: the run's `started_at` is
  always the cutoff, and against a cutoff an undated line is ambiguous — the
  same under-report-rather-than-misattribute rule the token reader uses for a
  `--resume`-shared file. (`occurred_at` still falls back to the run's start
  defensively, so a future caller that passes no cutoff cannot write a row
  with no time at all.) Redaction ran against the secret values known
  *now*, not the ones the run held. Every such row is tagged `source: "backfill"` so an analysis that
  cares can tell them apart from live capture.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.StepSummary
  alias Arbiter.Workers.{Run, RunStep}

  @type status :: :ok | :no_session_id | :no_session_file | :unreadable

  @type run_report :: %{
          run_id: String.t(),
          task_id: String.t() | nil,
          status: status(),
          inserted: non_neg_integer(),
          existing: non_neg_integer(),
          failed: non_neg_integer()
        }

  @type report :: %{
          scanned: non_neg_integer(),
          inserted: non_neg_integer(),
          existing: non_neg_integer(),
          failed: non_neg_integer(),
          no_session_id: non_neg_integer(),
          no_session_file: non_neg_integer(),
          unreadable: non_neg_integer(),
          apply?: boolean()
        }

  @doc """
  Backfill every run matching the filters, returning an aggregate report.

  ## Options

    * `:apply?` — actually write rows. Defaults to `false` (dry run).
    * `:since` / `:until` — `DateTime` bounds on the run's `started_at`.
    * `:repo` — restrict to one repo.
    * `:limit` — cap how many runs are visited (oldest first, so repeated
      capped passes make forward progress).
    * `:redact_values` — secret values to scrub from summaries. See the
      moduledoc on why this is weaker than the live path's.

  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    opts
    |> candidate_runs()
    |> Enum.reduce(blank_report(Keyword.get(opts, :apply?, false)), fn run, acc ->
      {:ok, r} = backfill_run(run, opts)
      absorb(acc, r)
    end)
  end

  @doc """
  Backfill a single run. Always `{:ok, report}` — a missing session file or a
  torn JSONL is a *result*, not an error, because a sweep over hundreds of
  runs must not abort on one of them.
  """
  @spec backfill_run(Run.t() | struct(), keyword()) :: {:ok, run_report()}
  def backfill_run(run, opts \\ []) do
    case ClaudeSessionFile.locate(run.config_dir, run.session_id) do
      {:ok, path} -> backfill_from(run, path, opts)
      :not_found -> {:ok, blank_run_report(run, missing_status(run))}
    end
  end

  # ---- internals ---------------------------------------------------------

  defp backfill_from(run, path, opts) do
    case ClaudeSessionFile.read_steps(path, since: run.started_at) do
      {:ok, steps} ->
        {:ok, insert_steps(run, steps, opts)}

      {:error, reason} ->
        Logger.warning(
          "StepBackfill: unreadable session file for run=#{run.id} path=#{path}: #{inspect(reason)}"
        )

        {:ok, blank_run_report(run, :unreadable)}
    end
  end

  defp insert_steps(run, steps, opts) do
    apply? = Keyword.get(opts, :apply?, false)
    redact_values = Keyword.get(opts, :redact_values, [])
    known = existing_tool_use_ids(run)

    {fresh, existing} = Enum.split_with(steps, &(not MapSet.member?(known, &1.tool_use_id)))

    failed =
      if apply? do
        Enum.count(fresh, &(write_step(run, &1, redact_values) == :error))
      else
        0
      end

    %{
      run_id: run.id,
      task_id: run.task_id,
      status: :ok,
      inserted: length(fresh) - failed,
      existing: length(existing),
      failed: failed
    }
  end

  # A `tool_use_id` is unique within a session, so it is the natural
  # idempotency key — and it is the same key the live path stores, which is
  # what makes a mixed run (live rows plus a later backfill) converge.
  defp existing_tool_use_ids(run) do
    RunStep
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.Query.select([:tool_use_id])
    |> Ash.read!()
    |> MapSet.new(& &1.tool_use_id)
  end

  defp write_step(run, step, redact_values) do
    attrs = %{
      run_id: run.id,
      task_id: run.task_id,
      tool_use_id: step.tool_use_id,
      name: step.name,
      is_error: step.is_error,
      duration_ms: step.duration_ms,
      input_digest: StepSummary.input_digest(step.input, redact_values),
      input_summary: StepSummary.input_summary(step.input, redact_values),
      output_summary: StepSummary.output_summary(step.output_text, redact_values),
      occurred_at: step.occurred_at || run.started_at,
      source: "backfill"
    }

    case Ash.create(RunStep, attrs) do
      {:ok, _row} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "StepBackfill: could not write step run=#{run.id} tool_use_id=#{step.tool_use_id}: " <>
            Exception.message(error)
        )

        :error
    end
  end

  defp candidate_runs(opts) do
    query =
      Run
      |> Ash.Query.new()
      |> Ash.Query.sort(started_at: :asc)

    query
    |> filter_repo(Keyword.get(opts, :repo))
    |> filter_since(Keyword.get(opts, :since))
    |> filter_until(Keyword.get(opts, :until))
    |> limit(Keyword.get(opts, :limit))
    |> Ash.read!()
  end

  defp filter_repo(query, nil), do: query
  defp filter_repo(query, repo), do: Ash.Query.filter(query, repo == ^repo)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = since), do: Ash.Query.filter(query, started_at >= ^since)

  defp filter_until(query, nil), do: query
  defp filter_until(query, %DateTime{} = until), do: Ash.Query.filter(query, started_at < ^until)

  defp limit(query, n) when is_integer(n) and n > 0, do: Ash.Query.limit(query, n)
  defp limit(query, _n), do: query

  # A run that never recorded a session id cannot be located at all; one that
  # did but whose file is gone was reaped. Different problems, different fixes.
  defp missing_status(%{session_id: id}) when is_binary(id) and id != "", do: :no_session_file
  defp missing_status(_run), do: :no_session_id

  defp blank_run_report(run, status) do
    %{run_id: run.id, task_id: run.task_id, status: status, inserted: 0, existing: 0, failed: 0}
  end

  defp blank_report(apply?) do
    %{
      scanned: 0,
      inserted: 0,
      existing: 0,
      failed: 0,
      no_session_id: 0,
      no_session_file: 0,
      unreadable: 0,
      apply?: apply?
    }
  end

  defp absorb(acc, r) do
    acc
    |> Map.update!(:scanned, &(&1 + 1))
    |> Map.update!(:inserted, &(&1 + r.inserted))
    |> Map.update!(:existing, &(&1 + r.existing))
    |> Map.update!(:failed, &(&1 + r.failed))
    |> bump_status(r.status)
  end

  defp bump_status(acc, :ok), do: acc
  defp bump_status(acc, status), do: Map.update!(acc, status, &(&1 + 1))
end
