defmodule Arbiter.Workers.SessionArchiveBackfill do
  @moduledoc """
  One-time sweep that rescues the session JSONLs still on disk for runs that
  finished before `Arbiter.Worker.SessionArchive` shipped (bd-db0p38).

  Live archiving only ever sees the future, and the past is on a clock: Claude
  Code prunes its session store at ~21 days, so every day this sweep is not
  run, more of the surviving corpus becomes irrecoverable. An audit on
  2026-09-12 measured 16,596 files on disk with the oldest at 27 days and
  **nothing at all before 2026-08-22** — the entire July corpus was already
  gone. Of 2,308 runs carrying a `session_id`, 1,265 still had a file.

  Same shape as `Arbiter.Workers.StepBackfill`, deliberately, so an operator
  who has run one knows how to run the other:

    * **Dry by default.** `backfill/1` reports what it *would* archive unless
      passed `apply?: true`.
    * **Idempotent.** A run that already has an archive is skipped and counted
      as `already_archived`, so re-running converges instead of rewriting the
      corpus. Pass `force: true` to re-archive anyway (e.g. after widening the
      redaction list).
    * **Honest gaps.** `no_session_file` (pruned — irrecoverable),
      `no_session_id` (the run never reached an `init` event) and
      `no_config_dir` (not a Claude run at all) are *counted*, not silently
      dropped. A report that says "2,308 runs, 1,043 already pruned" is
      usable; one that says "1,265 archived" is not.
    * **Same redaction choke-point.** Everything goes through
      `Arbiter.Worker.SessionArchive`, which redacts via `Arbiter.Redaction`
      and writes `0600`. See that module for why redaction on a backfill is
      strictly weaker than on the live path.

  Run it with `mix arbiter.archive_sessions`.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Worker.SessionArchive
  alias Arbiter.Workers.Run

  @type report :: %{
          scanned: non_neg_integer(),
          archived: non_neg_integer(),
          already_archived: non_neg_integer(),
          no_config_dir: non_neg_integer(),
          no_session_id: non_neg_integer(),
          no_session_file: non_neg_integer(),
          too_large: non_neg_integer(),
          error: non_neg_integer(),
          bytes_in: non_neg_integer(),
          bytes_out: non_neg_integer(),
          subagents: non_neg_integer(),
          apply?: boolean()
        }

  @doc """
  Sweep every run matching the filters, returning an aggregate report.

  ## Options

    * `:apply?` — actually write archives. Defaults to `false` (dry run).
    * `:force` — re-archive runs that already have an archive.
    * `:since` / `:until` — `DateTime` bounds on the run's `started_at`.
    * `:repo` — restrict to one repo.
    * `:limit` — cap how many runs are visited (oldest first, so repeated
      capped passes make forward progress).
    * `:redact_values` — override the secret values to scrub. Defaults, per
      run, to its workspace's current secrets.

  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)
    force? = Keyword.get(opts, :force, false)

    opts
    |> candidate_runs()
    |> Enum.reduce(blank_report(apply?), fn run, acc ->
      absorb(acc, archive_one(run, apply?, force?, opts))
    end)
  end

  # A dry run must still tell the truth about *which* runs are rescuable, so
  # it resolves the file exactly as a real pass would — it just stops short of
  # writing. `SessionArchive.archive_run/2` has no dry mode (nothing else
  # needs one), so the dry path locates and classifies here instead.
  defp archive_one(run, apply?, force?, opts) do
    cond do
      not force? and SessionArchive.archived?(run.id) ->
        %{status: :already_archived, bytes_in: 0, bytes_out: 0, subagents: 0}

      apply? ->
        {:ok, report} = SessionArchive.archive_run(run, archive_opts(opts))

        %{
          status: rename_ok(report.status),
          bytes_in: report.bytes_in,
          bytes_out: report.bytes_out,
          subagents: report.subagents
        }

      true ->
        %{status: dry_status(run), bytes_in: 0, bytes_out: 0, subagents: 0}
    end
  end

  defp archive_opts(opts) do
    case Keyword.fetch(opts, :redact_values) do
      {:ok, values} -> [redact_values: values]
      :error -> []
    end
  end

  defp rename_ok(:ok), do: :archived
  defp rename_ok(other), do: other

  # Classify without writing: the same three coordinate checks
  # `SessionArchive.archive/4` makes, so the dry report matches the apply run.
  defp dry_status(run) do
    cond do
      run.config_dir in [nil, ""] ->
        :no_config_dir

      run.session_id in [nil, ""] ->
        :no_session_id

      true ->
        case Arbiter.Usage.ClaudeSessionFile.locate(run.config_dir, run.session_id) do
          {:ok, _path} -> :archived
          :not_found -> :no_session_file
        end
    end
  end

  defp candidate_runs(opts) do
    Run
    |> Ash.Query.new()
    |> Ash.Query.sort(started_at: :asc)
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

  defp blank_report(apply?) do
    %{
      scanned: 0,
      archived: 0,
      already_archived: 0,
      no_config_dir: 0,
      no_session_id: 0,
      no_session_file: 0,
      too_large: 0,
      error: 0,
      bytes_in: 0,
      bytes_out: 0,
      subagents: 0,
      apply?: apply?
    }
  end

  defp absorb(acc, r) do
    acc
    |> Map.update!(:scanned, &(&1 + 1))
    |> Map.update!(:bytes_in, &(&1 + r.bytes_in))
    |> Map.update!(:bytes_out, &(&1 + r.bytes_out))
    |> Map.update!(:subagents, &(&1 + r.subagents))
    |> Map.update!(r.status, &(&1 + 1))
  end
end
