defmodule ArbiterCli.Cmd.Create do
  @moduledoc """
  `arb create <title> [--description ...] [--priority N] [--type T]
                       [--deps id1,id2] [--labels a,b] [--assignee a]`

  Creates a new issue in the resolved workspace (see `ArbiterCli.Workspace`).

  `--deps id1,id2` is a convenience that creates `blocks` dependencies for
  each listed issue (each becomes `<dep_id> blocks <new_id>`) AFTER the issue
  itself is created. If any dependency creation fails the new issue is left
  in place — the failure is reported and arb exits non-zero.

  `--labels` is accepted for interface parity with `bd` but the current Issue
  resource has no `labels` field; the value is reported back in a warning
  unless `--json` is set. See the BUILD-SUMMARY for the deviation.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [
    description: :string,
    priority: :integer,
    type: :string,
    deps: :string,
    labels: :string,
    assignee: :string,
    json: :boolean
  ]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    title =
      case rest do
        [t] -> t
        [] -> Output.die("create requires a title argument")
        many -> Enum.join(many, " ")
      end

    workspace_id = Workspace.id_or_halt()

    payload =
      %{"title" => title, "workspace_id" => workspace_id}
      |> maybe_put("description", opts[:description])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("issue_type", opts[:type])
      |> maybe_put("assignee", opts[:assignee])

    if opts[:labels] && mode == :text do
      IO.puts(
        :stderr,
        "arb: warning: --labels is accepted for interface parity but the Issue resource has no labels field (ignored)."
      )
    end

    issue =
      case Client.post("/api/issues", payload) do
        {:ok, body} -> body
        {:error, err} -> Output.die(err)
      end

    if opts[:deps] do
      attach_deps(issue["id"], opts[:deps])
    end

    Output.emit_issue(issue, mode)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp attach_deps(new_id, raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.each(fn dep_id ->
      body = %{"from_issue_id" => dep_id, "to_issue_id" => new_id, "type" => "blocks"}

      case Client.post("/api/dependencies", body) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Output.die(%{
            err
            | message: "failed to add dependency #{dep_id} -> #{new_id}: #{err.message}"
          })
      end
    end)
  end
end
