defmodule ArbiterWeb.StatusHelpersTest do
  use ExUnit.Case

  alias ArbiterWeb.StatusHelpers

  describe "worker_status_class/1" do
    test "returns correct badge class for each status" do
      assert StatusHelpers.worker_status_class(:idle) == "badge-ghost"
      assert StatusHelpers.worker_status_class(:running) == "badge-info"
      assert StatusHelpers.worker_status_class(:awaiting) == "badge-warning"
      assert StatusHelpers.worker_status_class(:completed) == "badge-success"
      assert StatusHelpers.worker_status_class(:failed) == "badge-error"
      assert StatusHelpers.worker_status_class(:unknown) == ""
    end
  end

  describe "worker_status_label/1" do
    test "returns correct label for each status" do
      assert StatusHelpers.worker_status_label(:idle) == "Idle"
      assert StatusHelpers.worker_status_label(:running) == "Running"
      assert StatusHelpers.worker_status_label(:awaiting) == "Awaiting"
      assert StatusHelpers.worker_status_label(:completed) == "Completed"
      assert StatusHelpers.worker_status_label(:failed) == "Failed"
    end

    test "capitalizes unknown atoms" do
      assert StatusHelpers.worker_status_label(:some_status) == "Some_status"
    end

    test "converts non-atoms to strings" do
      assert StatusHelpers.worker_status_label("string_status") == "string_status"
    end
  end

  describe "difficulty_badge_class/1" do
    test "returns correct badge class for each difficulty level" do
      assert StatusHelpers.difficulty_badge_class(nil) == "badge-ghost"
      assert StatusHelpers.difficulty_badge_class(0) == "badge-success"
      assert StatusHelpers.difficulty_badge_class(1) == "badge-info"
      assert StatusHelpers.difficulty_badge_class(2) == "badge-secondary"
      assert StatusHelpers.difficulty_badge_class(3) == "badge-warning"
      assert StatusHelpers.difficulty_badge_class(4) == "badge-error"
      assert StatusHelpers.difficulty_badge_class(5) == "badge-ghost"
    end
  end

  describe "run_status_class/1" do
    test "returns correct badge class for each run status" do
      assert StatusHelpers.run_status_class(:completed) == "badge-success"
      assert StatusHelpers.run_status_class(:failed) == "badge-error"
      assert StatusHelpers.run_status_class(:running) == "badge-info"
      assert StatusHelpers.run_status_class(:unknown) == "badge-ghost"
    end
  end

  describe "kind_badge_class/1" do
    test "returns correct badge class for each notification kind" do
      assert StatusHelpers.kind_badge_class(:notification) == "badge-info"
      assert StatusHelpers.kind_badge_class(:direction) == "badge-warning"
      assert StatusHelpers.kind_badge_class(:flag) == "badge-accent"
      assert StatusHelpers.kind_badge_class(:unknown) == "badge-ghost"
    end
  end

  describe "status_dot_class/1" do
    test "returns correct background class for each status" do
      assert StatusHelpers.status_dot_class(:running) == "bg-info"
      assert StatusHelpers.status_dot_class(:awaiting) == "bg-warning"
      assert StatusHelpers.status_dot_class(:completed) == "bg-success"
      assert StatusHelpers.status_dot_class(:failed) == "bg-error"
      assert StatusHelpers.status_dot_class(:unknown) == "bg-base-content/30"
    end
  end

  describe "format_ts_short/1" do
    test "formats DateTime as short time" do
      dt = ~U[2023-01-15 14:30:45Z]
      assert StatusHelpers.format_ts_short(dt) == "14:30:45"
    end

    test "returns empty string for non-DateTime" do
      assert StatusHelpers.format_ts_short(nil) == ""
      assert StatusHelpers.format_ts_short("invalid") == ""
    end
  end

  describe "format_ts_long/1" do
    test "formats DateTime as long timestamp" do
      dt = ~U[2023-01-15 14:30:45Z]
      assert StatusHelpers.format_ts_long(dt) == "2023-01-15 14:30:45 UTC"
    end

    test "returns empty string for non-DateTime" do
      assert StatusHelpers.format_ts_long(nil) == ""
      assert StatusHelpers.format_ts_long("invalid") == ""
    end
  end

  describe "flow_state/2" do
    test "returns :done for steps before current status" do
      assert StatusHelpers.flow_state(:idle, :running) == :done
      assert StatusHelpers.flow_state(:idle, :awaiting) == :done
      assert StatusHelpers.flow_state(:running, :awaiting) == :done
    end

    test "returns :current for the current status" do
      assert StatusHelpers.flow_state(:idle, :idle) == :current
      assert StatusHelpers.flow_state(:running, :running) == :current
    end

    test "returns :todo for steps after current status" do
      assert StatusHelpers.flow_state(:running, :idle) == :todo
      assert StatusHelpers.flow_state(:awaiting, :running) == :todo
    end

    test "returns :todo for invalid step or status" do
      assert StatusHelpers.flow_state(:invalid, :running) == :todo
      assert StatusHelpers.flow_state(:running, :invalid) == :todo
    end
  end

  describe "flow_step_class/1" do
    test "returns correct class for each flow step state" do
      assert StatusHelpers.flow_step_class(:done) == "step-primary"
      assert StatusHelpers.flow_step_class(:current) == "step-primary"
      assert StatusHelpers.flow_step_class(:todo) == ""
    end
  end

  describe "flow_step_marker/1" do
    test "returns check mark for done steps" do
      assert StatusHelpers.flow_step_marker(:done) == "✓"
    end

    test "returns nil for non-done steps" do
      assert StatusHelpers.flow_step_marker(:current) == nil
      assert StatusHelpers.flow_step_marker(:todo) == nil
    end
  end

  describe "flow_step_label/1" do
    test "returns correct label for each step" do
      assert StatusHelpers.flow_step_label(:idle) == "Idle"
      assert StatusHelpers.flow_step_label(:running) == "Running"
      assert StatusHelpers.flow_step_label(:awaiting) == "Awaiting review"
      assert StatusHelpers.flow_step_label(:completed) == "Completed"
    end
  end

  describe "worker_flow/0" do
    test "returns the worker flow sequence" do
      assert StatusHelpers.worker_flow() == [:idle, :running, :awaiting, :completed]
    end
  end
end
