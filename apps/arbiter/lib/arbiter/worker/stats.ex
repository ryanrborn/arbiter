defmodule Arbiter.Worker.Stats do
  @moduledoc false

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
  # *less* than a single ReviewGate round for the same task. Roll up by each
  # event's base task id instead, matching how `review_gate_rounds_list` and
  # `Arbiter.Usage.base_task_id/1` already attribute this spend.
  def task_costs_usd(task_ids) when is_list(task_ids) do
    base_ids = MapSet.new(task_ids)

    Arbiter.Usage.Event
    |> Ash.read!()
    |> Enum.group_by(&Arbiter.Worker.ReviewGate.base_task_id(&1.task_id))
    |> Enum.filter(fn {base_id, _events} -> MapSet.member?(base_ids, base_id) end)
    |> Map.new(fn {id, events} ->
      total = Enum.reduce(events, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
      {id, total}
    end)
  rescue
    _ -> %{}
  end
end
