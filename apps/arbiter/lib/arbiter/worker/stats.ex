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

  def task_costs_usd(task_ids) when is_list(task_ids) do
    require Ash.Query

    Arbiter.Usage.Event
    |> Ash.Query.filter(task_id in ^task_ids)
    |> Ash.read!()
    |> Enum.group_by(& &1.task_id)
    |> Map.new(fn {id, events} ->
      total = Enum.reduce(events, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
      {id, total}
    end)
  rescue
    _ -> %{}
  end
end
