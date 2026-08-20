defmodule Arbiter.Worker.Stats do
  @moduledoc false

  require Ash.Expr

  def short_model_name(nil), do: nil

  def short_model_name(model) when is_binary(model) do
    cond do
      String.contains?(model, "opus") -> "Opus"
      String.contains?(model, "sonnet") -> "Sonnet"
      String.contains?(model, "haiku") -> "Haiku"
      String.contains?(model, "fable") -> "Fable"
      true -> model
    end
  end

  def short_model_name(_), do: nil

  def task_costs_usd([]), do: %{}

  # bd-5fhyry: task cost aggregation now uses explicit base_task_id/role
  # columns instead of suffix stripping. Each id in `task_ids` gets its own
  # key in the result: a base id (derived from an already-synthetic id by
  # stripping suffixes) rolls up all events for that base plus any review/impl
  # passes; an already-synthetic id is matched exactly against the task_id
  # column (exact match, no rollup).
  def task_costs_usd(task_ids) when is_list(task_ids) do
    events =
      Arbiter.Usage.Event
      |> Ash.Query.do_filter(task_id_or_base_task_id_filter(task_ids))
      |> Ash.Query.select([:task_id, :base_task_id, :cost_usd])
      |> Ash.read!()

    by_exact_task_id = Enum.group_by(events, & &1.task_id)
    by_base_task_id = Enum.group_by(events, & &1.base_task_id)

    Map.new(task_ids, fn id ->
      base_id = Arbiter.Worker.ReviewGate.base_task_id(id)

      rows =
        if id == base_id do
          Map.get(by_base_task_id, id, [])
        else
          Map.get(by_exact_task_id, id, [])
        end

      {id, Enum.reduce(rows, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)}
    end)
  rescue
    _ -> %{}
  end

  # Filter by exact task_id match or by base_task_id (to capture all review/impl
  # passes under a base task). Uses the task_id_or_base_task_id index for speed.
  defp task_id_or_base_task_id_filter(task_ids) do
    Enum.reduce(task_ids, nil, fn id, acc ->
      base_id = Arbiter.Worker.ReviewGate.base_task_id(id)

      condition =
        if id == base_id do
          Ash.Expr.expr(base_task_id == ^id)
        else
          Ash.Expr.expr(task_id == ^id)
        end

      if is_nil(acc), do: condition, else: Ash.Expr.expr(^acc or ^condition)
    end)
  end
end
