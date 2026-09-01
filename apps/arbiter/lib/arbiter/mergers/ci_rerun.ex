defmodule Arbiter.Mergers.CIRerun do
  @moduledoc """
  Picks the *granularity* of a CI re-run (bd-5mzzww / #1448).

  A forge offers more than one way to re-run a red pipeline, and they are not
  interchangeable:

    * `:failed_jobs` — re-run only the jobs that failed, reusing every job that
      already succeeded (GitHub's "Re-run failed jobs", the default button in
      the UI and therefore the path of least resistance for a human).
    * `:all_jobs` — re-run the whole workflow run from scratch, rebuilding the
      upstream jobs too (GitHub's "Re-run all jobs").
    * `:workflow` — a fresh `workflow_dispatch` of the workflow on the PR's head
      ref, optionally with inputs (e.g. `force_deploy: true`).

  ## Why the granularity matters

  From the incident this module exists for: a `playwright-smoke` check ran
  against a per-branch review app that *earlier jobs in the same run* deployed.
  Re-running only the failed job re-tested the same stale deployment — twice,
  by hand, 19 hours apart, both times deterministically failing. Only a full
  re-dispatch rebuilt the review app and went green.

  Generalised: **whenever a failing check depends on an artifact produced by an
  earlier job in the same run, a failed-jobs re-run cannot clear an
  environmental failure.** It re-tests the identical inputs and is guaranteed to
  produce the identical answer.

  ## The policy

  `choose/1` reads a workflow run's metadata and returns the cheapest re-run
  that could actually tell us something new:

  1. The caller supplied workflow **inputs** → `:workflow`. Inputs only exist on
     a `workflow_dispatch`; honouring them any other way would silently drop
     them.
  2. This is already **attempt ≥ 2** → `:all_jobs`. A failed-jobs re-run has
     been tried and failed; a second identical one is never informative.
  3. The run has jobs that **completed successfully** → `:all_jobs`. Those are
     exactly the jobs a failed-jobs re-run would reuse, so they are exactly the
     ones that must be rebuilt if the failure is environmental.
  4. Otherwise → `:failed_jobs`, the cheapest option.

  Skipped/cancelled jobs are deliberately not counted in (3): they produced no
  artifact, so re-running them buys nothing.

  Pure and provider-agnostic — adapters map the chosen mode onto their own API.
  """

  @type mode :: :failed_jobs | :all_jobs | :workflow

  @type decision :: %{
          mode: mode(),
          rationale: String.t(),
          reused_jobs: [String.t()],
          run_attempt: pos_integer()
        }

  @doc """
  Choose a re-run mode for one workflow run.

  `run` accepts (all optional, missing keys degrade to the cheapest re-run):

    * `:run_attempt` — 1-based attempt counter for the run.
    * `:jobs` — the run's jobs as the forge returned them (string-keyed maps
      with `"name"` and `"conclusion"`).
    * `:inputs` — workflow inputs the caller asked to dispatch with.
  """
  @spec choose(map()) :: decision()
  def choose(run) when is_map(run) do
    attempt = attempt(Map.get(run, :run_attempt))
    inputs = Map.get(run, :inputs) || %{}
    reused = reusable_jobs(Map.get(run, :jobs))

    {mode, rationale} = decide(attempt, inputs, reused)

    %{mode: mode, rationale: rationale, reused_jobs: reused, run_attempt: attempt}
  end

  @doc """
  Render a `choose/1` decision as one human-readable line, for tool output and
  coordinator escalations.
  """
  @spec explain(decision()) :: String.t()
  def explain(%{mode: mode, rationale: rationale}), do: "#{mode}: #{rationale}"

  # ---- internals -----------------------------------------------------------

  defp decide(_attempt, inputs, _reused) when map_size(inputs) > 0 do
    {:workflow,
     "caller supplied workflow inputs (#{inputs |> Map.keys() |> Enum.sort() |> Enum.join(", ")}), " <>
       "which only a fresh workflow_dispatch can carry"}
  end

  defp decide(attempt, _inputs, reused) when attempt > 1 do
    {:all_jobs,
     "this run is already at attempt #{attempt} — a failed-jobs re-run has been tried and " <>
       "failed, and repeating it re-tests identical inputs" <> reused_suffix(reused)}
  end

  defp decide(_attempt, _inputs, [_ | _] = reused) do
    {:all_jobs,
     "#{length(reused)} completed upstream job(s) (#{Enum.join(reused, ", ")}) would be reused " <>
       "by a failed-jobs re-run, so an environmental failure in their output could not clear"}
  end

  defp decide(_attempt, _inputs, []) do
    {:failed_jobs,
     "no completed upstream jobs to rebuild — re-running just the failed job(s) tests " <>
       "everything a full re-run would"}
  end

  defp reused_suffix([]), do: ""
  defp reused_suffix(reused), do: " (would reuse: #{Enum.join(reused, ", ")})"

  # Only `success` counts: a skipped or cancelled job produced no artifact for a
  # downstream check to consume, so rebuilding it buys nothing.
  defp reusable_jobs(jobs) when is_list(jobs) do
    jobs
    |> Enum.filter(&(job_field(&1, "conclusion") == "success"))
    |> Enum.map(&(job_field(&1, "name") || "job"))
  end

  defp reusable_jobs(_), do: []

  defp job_field(job, key) when is_map(job), do: Map.get(job, key) || Map.get(job, safe_atom(key))
  defp job_field(_job, _key), do: nil

  defp safe_atom("name"), do: :name
  defp safe_atom("conclusion"), do: :conclusion

  defp attempt(n) when is_integer(n) and n > 0, do: n
  defp attempt(_), do: 1
end
