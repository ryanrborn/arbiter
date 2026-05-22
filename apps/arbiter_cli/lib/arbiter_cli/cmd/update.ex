defmodule ArbiterCli.Cmd.Update do
  @moduledoc """
  `arb update <id> [--priority N] [--append-notes text] [--status s]
                    [--description d] [--assignee a]`

  --append-notes appends the given string to the existing `notes` field
  (separated by two newlines). This requires fetching the issue first so we
  don't lose existing notes.
  """

  alias ArbiterCli.{Client, Output}

  @switches [
    priority: :integer,
    append_notes: :string,
    notes: :string,
    status: :string,
    description: :string,
    title: :string,
    assignee: :string,
    json: :boolean
  ]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    id =
      case rest do
        [id] -> id
        [] -> Output.die("update requires an issue id")
        _ -> Output.die("update takes exactly one positional argument: the issue id")
      end

    existing =
      if opts[:append_notes] do
        case Client.get("/api/issues/" <> id) do
          {:ok, body} -> body
          {:error, err} -> Output.die(err)
        end
      end

    payload =
      %{}
      |> put_if("priority", opts[:priority])
      |> put_if("notes", opts[:notes])
      |> put_if("status", opts[:status])
      |> put_if("description", opts[:description])
      |> put_if("title", opts[:title])
      |> put_if("assignee", opts[:assignee])
      |> maybe_append_notes(opts[:append_notes], existing)

    if map_size(payload) == 0 do
      Output.die("update requires at least one field flag (e.g. --priority, --append-notes)")
    end

    case Client.patch("/api/issues/" <> id, payload) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_notes(payload, nil, _existing), do: payload

  defp maybe_append_notes(payload, addition, existing) do
    combined =
      case existing["notes"] do
        n when n in [nil, ""] -> addition
        prev -> prev <> "\n\n" <> addition
      end

    Map.put(payload, "notes", combined)
  end
end
