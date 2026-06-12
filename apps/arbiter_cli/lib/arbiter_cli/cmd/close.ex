defmodule ArbiterCli.Cmd.Close do
  @moduledoc """
  `arb close <id> [--reason ...]` — close an issue.

  If the directive has a `tracker_ref` and a non-`:none` tracker type, the
  linked upstream tracker issue is automatically closed as well.
  """

  alias ArbiterCli.{Client, Output}

  @switches [reason: :string, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] -> id
          [] -> Output.die("close requires an issue id")
          _ -> Output.die("close takes exactly one positional argument: the issue id")
        end

      close_upstream =
        case Client.get("/api/issues/" <> id) do
          {:ok, issue} -> tracker_linked?(issue)
          {:error, _} -> false
        end

      body =
        %{}
        |> then(fn b -> if opts[:reason], do: Map.put(b, "reason", opts[:reason]), else: b end)
        |> then(fn b -> if close_upstream, do: Map.put(b, "close_upstream", true), else: b end)

      case Client.post("/api/issues/" <> id <> "/close", body) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp tracker_linked?(%{"tracker_type" => tracker_type, "tracker_ref" => tracker_ref}) do
    tracker_type not in [nil, "none", ""] and tracker_ref not in [nil, ""]
  end

  defp tracker_linked?(_), do: false
end
