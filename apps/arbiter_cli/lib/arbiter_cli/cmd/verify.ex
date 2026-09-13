defmodule ArbiterCli.Cmd.Verify do
  @moduledoc """
  `arb issue verify <id> --observed "<evidence>" | --failed "<evidence>"`

  Records the post-merge restart-and-observe result for a task parked at
  `awaiting_verification` (bd-9so315).

  A task flagged `verify_after_deploy` does not close when its PR merges: its
  only execution context is the long-lived server, so the merge proves nothing
  until someone restarts and looks. The task waits here until you say what you
  saw.

      arb issue verify bd-9so315 --observed "restarted 14:02; GET /api/doctor now reports 3 repos"
      arb issue verify bd-9so315 --failed   "after restart capture_source still reads headers"

  `--observed` closes the task. `--failed` reopens it for another attempt, with
  a fresh PR. Either way the evidence text is persisted on the task, so "this
  is live and working" is an auditable record rather than a memory.

  Wraps `POST /api/issues/:id/verify`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [observed: :string, failed: :string, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] -> id
          [] -> Output.die("verify requires an issue id", usage_hint())
          _ -> Output.die("verify takes exactly one positional argument: the issue id")
        end

      {outcome, evidence} = verdict!(opts)

      case Client.post("/api/issues/" <> id <> "/verify", %{
             "outcome" => outcome,
             "evidence" => evidence
           }) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp verdict!(opts) do
    case {opts[:observed], opts[:failed]} do
      {nil, nil} ->
        Output.die("verify requires --observed <evidence> or --failed <evidence>", usage_hint())

      {obs, fail} when is_binary(obs) and is_binary(fail) ->
        Output.die("verify takes --observed or --failed, not both")

      {obs, nil} ->
        {"observed", obs}

      {nil, fail} ->
        {"failed", fail}
    end
  end

  defp usage_hint do
    ~s(e.g. `arb issue verify bd-9so315 --observed "restarted; the new path fires"`)
  end
end
