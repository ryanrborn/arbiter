defmodule ArbiterWeb.StatusHelpers do
  @moduledoc """
  Shared helper functions for status badges, labels, and styling across LiveViews.

  These functions are extracted from dashboard_live, task_detail_live, and worker_detail_live
  to eliminate duplication and ensure consistent status/badge rendering across the app.
  """

  # Ordered worker lifecycle for the step progress stepper. :failed is handled
  # separately in templates (it doesn't belong on the happy-path track).
  @worker_flow [:idle, :running, :awaiting, :completed]

  def worker_flow, do: @worker_flow

  # ---- Status badges ----

  def difficulty_badge_class(nil), do: "badge-ghost"
  def difficulty_badge_class(0), do: "badge-success"
  def difficulty_badge_class(1), do: "badge-info"
  def difficulty_badge_class(2), do: "badge-secondary"
  def difficulty_badge_class(3), do: "badge-warning"
  def difficulty_badge_class(4), do: "badge-error"
  def difficulty_badge_class(_), do: "badge-ghost"

  def worker_status_class(:idle), do: "badge-ghost"
  def worker_status_class(:running), do: "badge-info"
  def worker_status_class(:awaiting), do: "badge-warning"
  def worker_status_class(:completed), do: "badge-success"
  def worker_status_class(:failed), do: "badge-error"
  def worker_status_class(_), do: ""

  def worker_status_label(:idle), do: "Idle"
  def worker_status_label(:running), do: "Running"
  def worker_status_label(:awaiting), do: "Awaiting"
  def worker_status_label(:completed), do: "Completed"
  def worker_status_label(:failed), do: "Failed"

  def worker_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  def worker_status_label(other), do: to_string(other)

  def run_status_class(:completed), do: "badge-success"
  def run_status_class(:failed), do: "badge-error"
  def run_status_class(:running), do: "badge-info"
  def run_status_class(_), do: "badge-ghost"

  def kind_badge_class(:notification), do: "badge-info"
  def kind_badge_class(:direction), do: "badge-warning"
  def kind_badge_class(:flag), do: "badge-accent"
  def kind_badge_class(_), do: "badge-ghost"

  def status_dot_class(:running), do: "bg-info"
  def status_dot_class(:awaiting), do: "bg-warning"
  def status_dot_class(:completed), do: "bg-success"
  def status_dot_class(:failed), do: "bg-error"
  def status_dot_class(_), do: "bg-base-content/30"

  # ---- Timestamp formatting ----

  def format_ts_short(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_ts_short(_), do: ""

  def format_ts_long(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_ts_long(_), do: ""

  # ---- Flow/stepper rendering ----

  def flow_state(step, status) do
    step_idx = Enum.find_index(@worker_flow, &(&1 == step))
    status_idx = Enum.find_index(@worker_flow, &(&1 == status))

    cond do
      is_nil(step_idx) or is_nil(status_idx) -> :todo
      step_idx < status_idx -> :done
      step_idx == status_idx -> :current
      true -> :todo
    end
  end

  def flow_step_class(:done), do: "step-primary"
  def flow_step_class(:current), do: "step-primary"
  def flow_step_class(:todo), do: ""

  def flow_step_marker(:done), do: "✓"
  def flow_step_marker(_), do: nil

  def flow_step_label(:idle), do: "Idle"
  def flow_step_label(:running), do: "Running"
  def flow_step_label(:awaiting), do: "Awaiting review"
  def flow_step_label(:completed), do: "Completed"
end
