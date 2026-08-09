defmodule Arbiter.Loop.Proposals do
  @moduledoc """
  Turns a `%Arbiter.Loop.Report{}` into **candidate** proposals for the Stage 2
  queue (bd-9j2g3x).

  `candidates/2` is pure — it maps an already-built report onto the candidate
  shape `Arbiter.Loop.record/2` accepts and writes nothing. `record_all/2` is
  the shell that persists them, and it only ever runs when the caller opted in
  with `propose?: true`, so `Arbiter.Loop.Analysis.analyze/1` keeps its
  zero-writes guarantee by default.

  ## What becomes a candidate, and what deliberately does not

    * **Every reviewer-finding category** becomes a `:skill_patch` candidate at
      `:fleet` scope — including the ones below the evidence bar. That is the
      point of Stage 2: a below-bar finding is kept as a `:hypothesis` carrying
      its incident refs instead of being discarded, so its third occurrence
      three weeks later counts from 1 + 2 rather than from zero. The bar is
      re-evaluated on the accumulated total by `Arbiter.Loop.record/2`, not
      here.

      These carry **no patch content**: there is currently no mapping from a
      finding category to a specific skill (`suggestion_targets/2` returns
      `destination: :skill` without ever naming one), so authoring the patch
      prose is Stage 3 work behind the category→skill attribution problem.
      Applying such a row fails cleanly, naming the gap.

    * **Rework difficulty misestimates** become `:difficulty_override`
      candidates at `:task` scope (blast radius 1, so they bypass the bar) with
      a concrete payload — `Issue.difficulty` + 1 on the named task — and a
      rendered unified diff.

    * **`:quality_failure` misestimates do not become candidates.** The report's
      own recommendation for them is *"investigate the agent-quality failures
      before recommending a difficulty change — this is a cost anomaly, not a
      rounds signal"*. Queueing a difficulty bump from a cost signal would fill
      the queue with writes the report itself declines to recommend.
  """

  alias Arbiter.Loop
  alias Arbiter.Loop.Report
  alias Arbiter.Tasks.Issue

  # `gist` is a one-liner in a table; long finding categories get elided.
  @gist_limit 160

  # Fallback for the `Issue.difficulty` ceiling if the constraint ever stops
  # declaring a max; `max_difficulty/0` prefers the resource's own value.
  @difficulty_ceiling 4

  @doc """
  The candidate proposals implied by `report`. Pure: no writes, no I/O.

  Options: `:workspace_id` (stamped on each candidate), `:origin` (defaults to
  `"loop.analyze"`).
  """
  @spec candidates(Report.t(), keyword()) :: [map()]
  def candidates(%Report{} = report, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    origin = Keyword.get(opts, :origin, "loop.analyze")

    finding_candidates(report, workspace_id, origin) ++
      misestimate_candidates(report, workspace_id, origin)
  end

  @doc """
  Persist every candidate implied by `report` through `Arbiter.Loop.record/2`,
  so each one is either inserted or reinforced onto the row with the same
  fingerprint. Returns the resulting rows (errors are logged and skipped so one
  bad candidate cannot abort the pass).
  """
  @spec record_all(Report.t(), keyword()) :: [Arbiter.Loop.PendingWrite.t()]
  def record_all(%Report{} = report, opts \\ []) do
    {record_opts, candidate_opts} = Keyword.split(opts, [:actor, :evidence_bar])

    report
    |> candidates(candidate_opts)
    |> Enum.reduce([], fn candidate, acc ->
      case Loop.record(candidate, record_opts) do
        {:ok, row} ->
          [row | acc]

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[loop.propose] skipped candidate #{inspect(candidate[:gist])}: #{inspect(reason)}"
          )

          acc
      end
    end)
    |> Enum.reverse()
  end

  # ---- reviewer-finding categories ----------------------------------------

  defp finding_candidates(report, workspace_id, origin) do
    by_title = Map.new(report.suggestions, &{&1.title, &1})

    Enum.map(report.finding_categories, fn cat ->
      suggestion = Map.get(by_title, cat.category, %{})

      %{
        kind: :skill_patch,
        scope: :fleet,
        category: cat.category,
        target: nil,
        difficulty: nil,
        repo: nil,
        gist: elide("working-practice guardrail for: #{cat.category}"),
        target_metric: Map.get(suggestion, :target_metric),
        baseline: Map.get(suggestion, :baseline),
        incident_refs: cat.run_ids,
        task_refs: cat.tasks,
        # No `skill` key: the target skill is not attributed yet (Stage 3). The
        # apply path refuses the row and says so rather than guessing.
        payload: %{
          "category" => cat.category,
          "example" => Map.get(cat, :example),
          "destination" => to_string(Map.get(suggestion, :destination) || :skill)
        },
        diff: nil,
        origin: origin,
        workspace_id: workspace_id
      }
    end)
  end

  # ---- difficulty misestimates --------------------------------------------

  defp misestimate_candidates(report, workspace_id, origin) do
    report.difficulty_misestimates
    |> Enum.filter(&proposable_misestimate?/1)
    |> Enum.map(fn m ->
      from = m.dispatched_difficulty
      to = from + 1
      rec = Map.get(m, :recommendation) || %{}
      repo = misestimate_repo(m)

      %{
        kind: :difficulty_override,
        scope: :task,
        category: "difficulty misestimate (rework)",
        target: m.task_id,
        difficulty: from,
        repo: repo,
        gist:
          elide(
            "raise difficulty on #{m.task_id}: D#{from} → D#{to} " <>
              "(#{m.rounds} review round(s), $#{fmt(m.cost_usd)})"
          ),
        target_metric: Map.get(rec, :target_metric),
        baseline: Map.get(rec, :baseline),
        # A misestimate is a task-level observation, so the task is its own
        # incident ref. Unioning on it keeps a re-run over the same window
        # idempotent, and a recurrence at the same difficulty is one incident,
        # not two.
        incident_refs: [m.task_id],
        task_refs: [m.task_id],
        payload: %{
          "task_id" => m.task_id,
          "difficulty" => to,
          "from_difficulty" => from,
          "reason" => "rework"
        },
        diff: difficulty_diff(m.task_id, from, to),
        origin: origin,
        workspace_id: workspace_id
      }
    end)
  end

  # Only the `:rework` reason names a concrete difficulty bump; a
  # `:quality_failure` is a cost anomaly the report explicitly declines to turn
  # into a difficulty change. A misestimate with no dispatched difficulty has
  # nothing to increment.
  #
  # A task already at the difficulty ceiling is skipped: `Issue.difficulty` is
  # constrained to 0..4, so a D4 → D5 override could never apply. Being
  # `:task`-scoped it would bypass the evidence bar and land directly as
  # `:proposed`, then fail its Ash validation on every `arb loop apply all`
  # forever — a permanently stuck queue entry.
  defp proposable_misestimate?(%{reason: :rework, dispatched_difficulty: d}) when is_integer(d),
    do: d < max_difficulty()

  defp proposable_misestimate?(_), do: false

  # Read from the resource so the ceiling cannot drift away from the constraint
  # the apply path is actually validated against.
  defp max_difficulty do
    case Ash.Resource.Info.attribute(Issue, :difficulty) do
      %{constraints: constraints} when is_list(constraints) ->
        constraints[:max] || @difficulty_ceiling

      _ ->
        @difficulty_ceiling
    end
  end

  defp misestimate_repo(%{cell: {_difficulty, repo}}) when is_binary(repo), do: repo
  defp misestimate_repo(_), do: nil

  # A minimal unified diff so `arb loop diff <id>` shows the change before it is
  # applied, in the same shape as any other reviewable patch.
  defp difficulty_diff(task_id, from, to) do
    """
    --- a/task/#{task_id}
    +++ b/task/#{task_id}
    @@ Issue.difficulty @@
    -difficulty: #{from}
    +difficulty: #{to}
    """
  end

  defp elide(text) when byte_size(text) <= @gist_limit, do: text

  defp elide(text) do
    text
    |> binary_part(0, @gist_limit - 1)
    |> Kernel.<>("…")
  end

  defp fmt(nil), do: "0.00"
  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
