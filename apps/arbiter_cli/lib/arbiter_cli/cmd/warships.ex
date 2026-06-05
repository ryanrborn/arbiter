defmodule ArbiterCli.Cmd.Warships do
  @moduledoc """
  `arb warships [--json]`

  Lists registered warships (rigs) from the active workspace config.
  Calls `GET /api/rigs` and formats the result as a table or JSON.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    case Client.get("/api/rigs") do
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

              Enum.each(rigs, fn rig ->
                :io.format(fmt, [
                  rig["name"] || "",
                  rig["source"] || "",
                  rig["path"] || ""
                ])
              end)
            end
        end

      {:error, err} ->
        Output.die(err)
    end
  end
end
