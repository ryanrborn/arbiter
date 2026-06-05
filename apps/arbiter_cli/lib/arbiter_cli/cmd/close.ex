defmodule ArbiterCli.Cmd.Close do
  @moduledoc """
  `arb close <id> [--reason ...] [--close-issue]` — close an issue.

  By default, the linked upstream tracker issue (e.g. GitHub issue) is left
  open. Pass `--close-issue` to also close it.
  """

  alias ArbiterCli.{Client, Output}

  @switches [reason: :string, json: :boolean, close_issue: :boolean]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    id =
      case rest do
        [id] -> id
        [] -> Output.die("close requires an issue id")
        _ -> Output.die("close takes exactly one positional argument: the issue id")
      end

    body =
      %{}
      |> then(fn b -> if opts[:reason], do: Map.put(b, "reason", opts[:reason]), else: b end)
      |> then(fn b ->
        if opts[:close_issue], do: Map.put(b, "close_upstream", true), else: b
      end)

    case Client.post("/api/issues/" <> id <> "/close", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
