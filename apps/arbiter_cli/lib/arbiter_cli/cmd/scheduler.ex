defmodule ArbiterCli.Cmd.Scheduler do
  @moduledoc """
  Board scheduler (autopilot) subcommand router:

      arb scheduler pause       — pause the autopilot (stop promoting Ready → Running)
      arb scheduler resume      — resume the autopilot
      arb scheduler status      — show current pause state

  Workers already dispatched continue to completion. When paused, no new
  dispatches occur. Coordinator only.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      rest = Output.drop_json(argv)
      mode = Output.mode(argv)

      case rest do
        ["pause" | _] ->
          pause(mode)

        ["resume" | _] ->
          resume(mode)

        ["status" | _] ->
          status(mode)

        _ ->
          IO.puts(:stderr, "arb: unknown scheduler subcommand")
          IO.puts(:stderr, "Run `arb scheduler --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp pause(mode) do
    case Client.post("/api/scheduler/pause", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler paused. Workers will continue to completion.")
        end

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp resume(mode) do
    case Client.post("/api/scheduler/resume", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler resumed. Autopilot is promoting Ready cards to Running.")
        end

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp status(mode) do
    case Client.get("/api/scheduler/status") do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          paused? = body["paused"]
          state = if paused?, do: "paused", else: "running"
          IO.puts("Board scheduler is #{state}.")
        end

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end
end
