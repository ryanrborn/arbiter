defmodule Arbiter.Worker.Stats do
  @moduledoc false

  # bd-8vnuy3: `task_costs_usd/1` lived here. Every surface that showed a
  # task's cost now reads `Arbiter.Usage.LiveSpend` instead, so the issue page,
  # `worker_list` and `arb worker list` cannot disagree on the same task.

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
end
