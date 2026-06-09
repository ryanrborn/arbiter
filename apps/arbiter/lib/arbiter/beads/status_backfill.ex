defmodule Arbiter.Beads.StatusBackfill do
  @moduledoc """
  Reconcile bead statuses in the database against git history on a branch.

  The cutover postmortem flagged that bead statuses in the original Dolt
  source drifted out of sync during late-Phase implementation: the Mayor
  stopped closing beads in Dolt once dogfood-switchover happened, so the
  `--sync-status` importer carried the stale `:open` statuses forward.

  This module reads `git log` for `feat(<bead-id>)` commit subjects on a
  configured branch (default `main`) and treats those as evidence the
  bead shipped. Any bead with such a commit whose current status isn't
  `:closed` gets a proposal to close. `apply!/1` performs the closures.

  ## What counts as evidence

  Only the `feat(<id>)` prefix is honored. `docs(<id>)`, `fix(<id>)`, and
  `test(<id>)` are intentionally skipped — those signal "work touched the
  bead" but not "the bead shipped". A bead with only docs/fix/test
  commits and no feat is left untouched.

  ## What this does NOT do

  - Detect reverts. If a `feat(<id>)` commit was reverted, the bead would
    still be proposed for closure. Operator inspection of the proposals
    list is the safety net for this.
  - Reopen beads. The reconciliation is one-directional (open → closed).
    A bead that's `:closed` in the database but has no `feat(<id>)` commit
    is left closed.
  """

  alias Arbiter.Beads.Issue

  @typedoc """
  A single closure proposal. `commit_sha` and `commit_subject` are the
  evidence; in dry-run mode they're shown to the operator before any
  writes happen.
  """
  @type proposal :: %{
          bead_id: String.t(),
          current_status: atom(),
          commit_sha: String.t(),
          commit_subject: String.t()
        }

  @doc """
  Build a list of closure proposals from git history.

  ## Options

    * `:branch` — git branch to scan (default `"main"`).
    * `:repo_path` — git repo root (default `File.cwd!()`).
    * `:git_log_lines` — for testing; bypasses `System.cmd("git", ...)`
      with a pre-baked list of `"<sha>|<subject>"` strings.
  """
  @spec proposals(keyword()) :: [proposal()]
  def proposals(opts \\ []) do
    lines = fetch_git_log_lines(opts)

    lines
    |> Enum.flat_map(&parse_line/1)
    |> consolidate()
    |> Enum.map(&attach_bead_status/1)
    |> Enum.reject(&already_closed_or_missing/1)
  end

  @doc """
  Apply proposals by closing each bead. Returns a tuple of
  `{closed :: [bead_id], errors :: [{bead_id, reason}]}`.

  Idempotent: re-running after success closes nothing (the beads are
  already closed and `proposals/1` filters them out next time).
  """
  @spec apply!([proposal()]) :: {[String.t()], [{String.t(), term()}]}
  def apply!(proposals) when is_list(proposals) do
    Enum.reduce(proposals, {[], []}, fn p, {ok, errs} ->
      reason =
        "Auto-closed by StatusBackfill (commit #{String.slice(p.commit_sha, 0, 7)}: #{p.commit_subject})"

      case close_bead(p.bead_id, reason) do
        :ok -> {[p.bead_id | ok], errs}
        {:error, reason} -> {ok, [{p.bead_id, reason} | errs]}
      end
    end)
    |> then(fn {ok, errs} -> {Enum.reverse(ok), Enum.reverse(errs)} end)
  end

  # ---- internals ---------------------------------------------------------

  defp fetch_git_log_lines(opts) do
    case Keyword.fetch(opts, :git_log_lines) do
      {:ok, lines} when is_list(lines) ->
        lines

      :error ->
        branch = Keyword.get(opts, :branch, "main")
        cd = Keyword.get(opts, :repo_path, File.cwd!())

        case System.cmd("git", ["log", "--pretty=format:%H|%s", branch], cd: cd) do
          {output, 0} -> String.split(output, "\n", trim: true)
          {_output, _nonzero} -> []
        end
    end
  end

  # Match the `feat(<bead-id>):` prefix. Bead id pattern matches the same
  # regex Issue uses for its primary key: `[a-z][a-zA-Z0-9]*-[a-zA-Z0-9]+`.
  @feat_pattern ~r/^feat\((?<id>[a-z][a-zA-Z0-9]*-[a-zA-Z0-9]+)\)/

  defp parse_line(line) do
    case String.split(line, "|", parts: 2) do
      [sha, subject] ->
        case Regex.named_captures(@feat_pattern, subject) do
          %{"id" => id} ->
            [%{bead_id: id, commit_sha: sha, commit_subject: subject}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # For beads referenced by multiple feat commits, keep the most recent
  # one (first in git-log output, which is newest-first by default).
  defp consolidate(parsed) do
    parsed
    |> Enum.reduce(%{}, fn p, acc ->
      Map.put_new(acc, p.bead_id, p)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.bead_id)
  end

  defp attach_bead_status(p) do
    case Ash.get(Issue, p.bead_id) do
      {:ok, %Issue{status: status}} -> Map.put(p, :current_status, status)
      _ -> Map.put(p, :current_status, :_missing)
    end
  end

  defp already_closed_or_missing(%{current_status: :closed}), do: true
  defp already_closed_or_missing(%{current_status: :_missing}), do: true
  defp already_closed_or_missing(_), do: false

  defp close_bead(bead_id, reason) do
    with {:ok, bead} <- Ash.get(Issue, bead_id),
         {:ok, _} <- Ash.update(bead, %{reason: reason}, action: :close) do
      :ok
    else
      {:error, err} -> {:error, err}
    end
  end
end
