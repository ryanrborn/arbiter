defmodule Arbiter.Loop.Canary.Metrics do
  @moduledoc """
  The measurement behind a Stage 3 canary: what each arm actually did.

  Everything here is derived from telemetry Arbiter already writes —
  `worker_runs`, `review_gate_rounds`, `usage_events`. No new dispatch-time
  recording, no migration, and nothing that has to be kept in sync with the
  routing decision: the arm is recomputed from the task id with the same
  function routing used, so a run recorded before this module existed is still
  attributable.

  Two numbers per arm:

    * **first-pass ReviewGate convergence** — of the tasks that reached review,
      the fraction whose *first* review round converged. This is the metric a
      routing-tier change is trying to move, and the one a regression reverts
      on;
    * **cost per review round** — reported for the operator's benefit, never a
      revert trigger. A tier change that buys convergence with money is a
      judgement call, not a regression.

  Reads follow the Corpus discipline: raw `Repo.query!/2` with bound
  parameters, scoped to the canary's own window and workspace, `IN` lists
  chunked so a long-running canary cannot build an unbounded statement.
  """

  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Loop.Canary
  alias Arbiter.Repo

  # SQLite's default parameter ceiling is 999; 200 keeps each statement small
  # with room to spare for the fixed params.
  @chunk 200

  @doc """
  Collect both arms' statistics for a running canary.

  Returns

      %{
        canary: arm_stats, control: arm_stats,
        difficulty:, proposal_id:, min_dispatches:, regression_tolerance:, since:
      }

  where `arm_stats` is `%{dispatches:, tasks:, reviewed_tasks:,
  first_pass_convergence:, cost_usd:, review_rounds:, cost_per_round:}`.
  `first_pass_convergence` and `cost_per_round` are `nil` when the arm has
  nothing to divide by — an absent measurement, never a zero.
  """
  @spec collect(String.t(), Canary.t()) :: map()
  def collect(workspace_id, %Canary{} = canary) do
    runs = dispatches(workspace_id, canary)

    {canary_runs, control_runs} =
      Enum.split_with(runs, &(Canary.arm(canary, &1.task_id) == :canary))

    task_ids = runs |> Enum.map(& &1.base_task_id) |> Enum.uniq()
    rounds = review_rounds(task_ids)
    costs = cost_by_run(Enum.map(runs, & &1.run_id))

    %{
      canary: arm_stats(canary_runs, rounds, costs),
      control: arm_stats(control_runs, rounds, costs),
      difficulty: canary.difficulty,
      proposal_id: canary.proposal_id,
      min_dispatches: canary.min_dispatches,
      regression_tolerance: canary.regression_tolerance,
      since: canary.started_at
    }
  end

  defp arm_stats(runs, rounds, costs) do
    tasks = runs |> Enum.map(& &1.base_task_id) |> Enum.uniq()
    reviewed = Enum.filter(tasks, &Map.has_key?(rounds, &1))
    first_pass = Enum.count(reviewed, &rounds[&1].first_pass_converged)
    review_rounds = reviewed |> Enum.map(&rounds[&1].rounds) |> Enum.sum()
    cost = runs |> Enum.map(&Map.get(costs, &1.run_id, 0.0)) |> Enum.sum()

    %{
      dispatches: length(runs),
      tasks: length(tasks),
      reviewed_tasks: length(reviewed),
      first_pass_convergence: ratio(first_pass, length(reviewed)),
      cost_usd: Float.round(cost / 1, 4),
      review_rounds: review_rounds,
      cost_per_round: if(review_rounds > 0, do: Float.round(cost / review_rounds, 4))
    }
  end

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n / d

  # ---- the window ---------------------------------------------------------

  # Main-worker dispatches at the canaried tier, in this workspace, since the
  # canary started. `difficulty_at_dispatch` is normalised through the routing
  # policy's own `effective_difficulty/1` so a run dispatched with no recorded
  # difficulty is counted in the tier routing actually gave it, not dropped.
  defp dispatches(workspace_id, %Canary{} = canary) do
    query(
      """
      SELECT id AS run_id, task_id, difficulty_at_dispatch
      FROM worker_runs
      WHERE workspace_id = ?1
        AND worker_type = 'main'
        AND started_at >= ?2
      """,
      [workspace_id, DateTime.to_iso8601(canary.started_at)]
    )
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.filter(
      &(ByDifficulty.effective_difficulty(&1["difficulty_at_dispatch"]) == canary.difficulty)
    )
    |> Enum.map(fn r ->
      %{run_id: r["run_id"], task_id: r["task_id"], base_task_id: base_task_id(r["task_id"])}
    end)
  end

  # Review rounds keyed by base task id: how many there were, and whether the
  # first one converged. Review rows carry a `#review`-suffixed task id, which
  # is exactly why the arm split keys on the base id too.
  defp review_rounds([]), do: %{}

  defp review_rounds(task_ids) do
    task_ids
    |> in_chunks(fn chunk, placeholders ->
      query(
        """
        SELECT task_id, round, converged
        FROM review_gate_rounds
        WHERE role = 'review'
          AND #{base_task_filter(placeholders)}
        """,
        chunk
      )
    end)
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.group_by(&base_task_id(&1["task_id"]))
    |> Map.new(fn {base, rows} ->
      first = Enum.min_by(rows, &int(&1["round"]))

      {base, %{rounds: length(rows), first_pass_converged: truthy?(first["converged"])}}
    end)
  end

  defp cost_by_run([]), do: %{}

  defp cost_by_run(run_ids) do
    run_ids
    |> in_chunks(fn chunk, placeholders ->
      query(
        """
        SELECT worker_run_id AS run_id, SUM(cost_usd) AS cost
        FROM usage_events
        WHERE worker_run_id IN (#{placeholders})
        GROUP BY worker_run_id
        """,
        chunk
      )
    end)
    |> Map.new(fn r -> {r["run_id"], flt(r["cost"])} end)
  end

  # A review row's task_id is the base id, optionally `#`-suffixed — match both
  # rather than pulling the whole table and filtering in Elixir.
  #
  # The whole disjunction is wrapped: it is spliced after an `AND`, and SQL
  # binds `AND` tighter than `OR`, so without the outer parentheses the
  # `role = 'review'` predicate would apply to the first task only and every
  # other task's `:impl` rows would be counted as review rounds.
  defp base_task_filter(placeholders) do
    inner =
      placeholders
      |> String.split(", ")
      |> Enum.map_join(" OR ", fn p -> "(task_id = #{p} OR task_id LIKE #{p} || '#%')" end)

    "(" <> inner <> ")"
  end

  defp in_chunks(values, fun) do
    values
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      placeholders = Enum.map_join(1..length(chunk), ", ", &"?#{&1}")
      fun.(chunk, placeholders)
    end)
  end

  defp query(sql, params) do
    %{columns: cols, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end

  defp base_task_id(nil), do: nil
  defp base_task_id(task_id), do: task_id |> String.split("#") |> hd()

  # SQLite has no boolean type: `converged` comes back as 1/0.
  defp truthy?(1), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp int(nil), do: 0
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(n) when is_binary(n), do: String.to_integer(n)

  defp flt(nil), do: 0.0
  defp flt(n) when is_number(n), do: n / 1
end
