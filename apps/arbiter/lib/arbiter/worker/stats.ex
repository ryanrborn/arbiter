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

  # bd-cryhwk: ReviewGate reviewer/implementer passes write their
  # `Arbiter.Usage.Event` rows under a synthetic, `#`-suffixed task id
  # (`Arbiter.Worker.ReviewGate.reviewer_task_id/1`,
  # `implementer_task_id/2` — e.g. "<base>#review", "<base>#review#impl1")
  # so the row is still attributable to the pass that earned it. Filtering
  # on exact `task_id` equality against the base ids silently dropped every
  # review/impl row, so the reported total could be (and was observed to be)
  # *less* than a single ReviewGate round for the same task.
  #
  # Every id in `task_ids` gets its own key in the result: a bare id (no
  # `#`) rolls up its own rows plus every synthetic id built from it; an
  # already-synthetic id (the caller asked for a specific ReviewGate pass)
  # is matched exactly, not rolled up again. Narrowed at the DB with an
  # exact-or-prefix filter (still index-friendly on `[:task_id,
  # :occurred_at]` for the exact leg) and a column select, so this no
  # longer pulls the whole `usage_events` table — including the `:raw`
  # per-row CLI payload — into memory on every `worker_list` call.
  def task_costs_usd(task_ids) when is_list(task_ids) do
    filter = task_id_filter(task_ids)

    events =
      Arbiter.Usage.Event
      |> Ash.Query.do_filter(filter)
      |> Ash.Query.select([:task_id, :cost_usd])
      |> Ash.read!()

    by_exact_id = Enum.group_by(events, & &1.task_id)
    by_base_id = Enum.group_by(events, &Arbiter.Worker.ReviewGate.base_task_id(&1.task_id))

    Map.new(task_ids, fn id ->
      rows =
        if id == Arbiter.Worker.ReviewGate.base_task_id(id) do
          Map.get(by_base_id, id, [])
        else
          Map.get(by_exact_id, id, [])
        end

      {id, Enum.reduce(rows, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)}
    end)
  rescue
    _ -> %{}
  end

  defp task_id_filter(task_ids) do
    Enum.reduce(task_ids, nil, fn id, acc ->
      condition = Ash.Expr.expr(task_id == ^id or string_starts_with(task_id, ^(id <> "#")))
      if is_nil(acc), do: condition, else: Ash.Expr.expr(^acc or ^condition)
    end)
  end
end
