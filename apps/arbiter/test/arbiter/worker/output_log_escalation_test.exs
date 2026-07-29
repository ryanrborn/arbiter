defmodule Arbiter.Worker.OutputLogEscalationTest do
  # DataCase so the Message row this raises is actually visible to the test's
  # DB connection (worker_test.exs runs plain ExUnit.Case, where the worker's
  # own best-effort Ash writes silently no-op outside a sandbox checkout).
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.State

  test "a transcript-capture failure raises a loud escalation, not a silent warning" do
    ws_id = "ws-output-log-#{System.unique_integer([:positive])}"
    task_id = "bd-output-log-#{System.unique_integer([:positive])}"
    run_id = Ecto.UUID.generate()

    state = %State{task_id: task_id, workspace_id: ws_id, run_id: run_id}

    assert :ok = Worker.escalate_output_log_failure(state, :eacces)

    mail = Message.inbox("coordinator", workspace_id: ws_id)
    escalation = Enum.find(mail, &(&1.directive_ref == task_id))

    assert escalation != nil
    assert escalation.kind == :escalation
    assert escalation.subject =~ task_id
    assert escalation.subject =~ "transcript"
    assert escalation.body =~ run_id
    assert escalation.body =~ "eacces"
  end
end
