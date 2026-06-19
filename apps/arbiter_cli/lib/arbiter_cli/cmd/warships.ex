defmodule ArbiterCli.Cmd.Warships do
  @moduledoc """
  `arb warships [--json]`

  Lists registered repos from the active workspace config.
  Calls `GET /api/repos` and formats the result as a table or JSON.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      case Client.get("/api/repos") do
        {:ok, %{"data" => rigs}} ->
          case mode do
            :json ->
              IO.puts(Jason.encode!(%{data: rigs}))

            :text ->
              if rigs == [] do
                IO.puts("(no warships registered)")
              else
                fmt = "~-24s ~-8s ~s~n"
                :io.format(fmt, ["NAME", "SOURCE", "PATH"])

                :io.format(fmt, [
                  String.duplicate("-", 24),
                  String.duplicate("-", 8),
                  String.duplicate("-", 40)
                ])

                Enum.each(rigs, fn repo ->
                  :io.format(fmt, [
                    repo["name"] || "",
                    repo["source"] || "",
                    repo["path"] || ""
                  ])
                end)
              end
          end

        {:error, err} ->
          Output.die(err)
      end
    end
  end
end
