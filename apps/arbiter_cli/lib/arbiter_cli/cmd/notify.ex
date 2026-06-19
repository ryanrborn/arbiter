defmodule ArbiterCli.Cmd.Notify do
  @moduledoc """
  `arb notify [--limit N]` — show the N most recent notifications (default 20).

  Read-only: notifications are broadcast events (worker completion, progress
  milestones, system events) and are never "consumed". This is the CLI window
  onto the same feed the dashboard renders live.

  Flags:
    --limit N   number of notifications to show (default 20)
    --json      emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  @default_limit 20

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      {opts, _rest, _invalid} = OptionParser.parse(rest, strict: [limit: :integer])
      limit = opts[:limit] || @default_limit

      case Client.get("/api/messages", kind: "notification", limit: limit) do
        {:ok, %{"data" => list}} -> emit(list, mode)
        {:ok, _} -> emit([], mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  # ---- render ----

  defp emit(notifications, :json), do: IO.puts(Jason.encode!(%{"data" => notifications}))

  defp emit([], :text), do: IO.puts("(no notifications)")

  defp emit(notifications, :text) do
    IO.puts("Recent notifications (#{length(notifications)}):")

    Enum.each(notifications, fn n ->
      ts = n["inserted_at"] || ""
      from = n["from_ref"]
      subject = n["subject"] || n["body"]
      from_label = if from, do: " #{from}", else: ""
      IO.puts("  #{ts}#{from_label}  #{subject}")
    end)
  end
end
