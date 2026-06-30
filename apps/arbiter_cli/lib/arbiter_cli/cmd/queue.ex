defmodule ArbiterCli.Cmd.Queue do
  @moduledoc """
  Graph-queue subcommand router (C5 of #482):

      arb queue resume <task-id>   — resume a paused branch by re-dispatching
                                     the failed task that blocked it

  When a graph member's worker fails, the Conductor pauses all tasks downstream
  of the failure and posts an escalation to the Admiral inbox. `resume` clears
  the failed state, re-dispatches the task, and allows the branch to continue.
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
end
