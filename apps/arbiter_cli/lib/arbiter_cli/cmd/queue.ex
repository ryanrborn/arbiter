defmodule ArbiterCli.Cmd.Queue do
  @moduledoc """
  Graph-queue subcommand router (C5 of #482):

      arb queue resume <task-id>               — resume a paused branch by
                                                  re-dispatching the failed
                                                  task that blocked it
      arb queue retry_auto_resolve <task-id>   — re-arm one more auto-resolve
                                                  attempt on a task's merge
                                                  Watchdog after it exhausted
                                                  its budget on a :ci_failed
                                                  block and parked (bd-bspakl)

  When a graph member's worker fails, the Conductor pauses all tasks downstream
  of the failure and posts an escalation to the coordinator inbox. `resume` clears
  the failed state, re-dispatches the task, and allows the branch to continue.

  `retry_auto_resolve` is the supported way to force a fresh fix-pass once the
  Watchdog's bounded auto-resolve retries are exhausted: without it, a task
  parked on a genuine `:ci_failed` block after exhaustion had no way to try
  again short of pushing a fix to the branch by hand, outside Arbiter's normal
  worker/review flow.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      rest = Output.drop_json(argv)
      mode = Output.mode(argv)

      case rest do
        ["resume", task_id | _] ->
          resume(task_id, mode)

        ["resume" | _] ->
          Output.die("queue resume requires: <task-id>")

        ["retry_auto_resolve", task_id | _] ->
          retry_auto_resolve(task_id, mode)

        ["retry_auto_resolve" | _] ->
          Output.die("queue retry_auto_resolve requires: <task-id>")

        _ ->
          IO.puts(:stderr, "arb: unknown queue subcommand")
          IO.puts(:stderr, "Run `arb queue --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp resume(task_id, mode) do
    case Client.post("/api/queue/#{task_id}/resume", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Resumed: #{task_id} re-dispatched. The downstream branch will continue once it completes."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "task #{task_id} is not in any running conductor's failed set.\n" <>
            "Either it has not failed, no graph is currently running, or it was already resumed."
        )

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp retry_auto_resolve(task_id, mode) do
    case Client.post("/api/queue/#{task_id}/retry_auto_resolve", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Re-armed: #{task_id} auto-resolve budget bumped by one and a poll fired now."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "no merge watchdog is currently running for task #{task_id}.\n" <>
            "Either the task never opened an MR, or its watchdog has already stopped."
        )

      {:error, %Client.Error{kind: :http, status: 400}} ->
        Output.die(
          "task #{task_id} is not currently parked on an exhausted :ci_failed block " <>
            "— there is nothing to re-arm."
        )

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end
end
