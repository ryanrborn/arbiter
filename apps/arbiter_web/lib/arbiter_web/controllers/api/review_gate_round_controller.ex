defmodule ArbiterWeb.Api.ReviewGateRoundController do
  @moduledoc """
  REST endpoint for structured ReviewGate round outcomes (bd-aqyjuc).

  Route:

    * `GET /api/review_gate_rounds?task_id=...` — list rounds for a task,
      oldest first, wrapped under the "data" key. One row per reviewer or
      implementer pass, so a round-1 rejection and a round-2 approval are
      two distinct rows rather than a single terminal outcome.
      Required query param: `task_id`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.ReviewGate.Round
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    rounds =
      Round
      |> Ash.Query.filter(task_id == ^task_id)
      # bd-6d3h8m: `round` restarts at 1 on every automatic fix round's fresh
      # gate; sort on `fix_round_attempt` first so the two passes don't
      # interleave.
      |> Ash.Query.sort(fix_round_attempt: :asc, round: :asc, inserted_at: :asc)
      |> Ash.read!()

    json(conn, %{data: Enum.map(rounds, &render_round/1)})
  end

  def index(_conn, _params) do
    {:error, {:invalid_request, "task_id is required"}}
  end

  defp render_round(%Round{} = r) do
    %{
      id: r.id,
      task_id: r.task_id,
      run_id: r.run_id,
      round: r.round,
      fix_round_attempt: r.fix_round_attempt,
      role: r.role,
      verdict: r.verdict,
      findings: r.findings,
      finding_count: r.finding_count,
      reviewer_model: r.reviewer_model,
      # bd-3hb4ih: which provider ran the pass. The only way to see a reviewer
      # print-timeout rotation (one `:timed_out` row per provider that hit its
      # CLI's own wall, then the verdict row naming the one that answered)
      # without re-reading transcripts.
      reviewer_provider: r.reviewer_provider,
      cost_usd: r.cost_usd,
      converged: r.converged,
      inserted_at: iso(r.inserted_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
