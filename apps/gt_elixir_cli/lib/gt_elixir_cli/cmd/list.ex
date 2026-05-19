defmodule GtElixirCli.Cmd.List do
  @moduledoc """
  `bd2 list [--status ...] [--type ...] [--priority N] [--labels ...]`

  Filters are passed through to `GET /api/issues` as query params. `--labels`
  is accepted for interface parity with `bd`, but the current Issue resource
  has no labels field — the flag is ignored with a stderr warning. See
  BUILD-SUMMARY for the deviation.
  """

  alias GtElixirCli.{Client, Output}

  @switches [
    status: :string,
    type: :string,
    priority: :integer,
    labels: :string,
    workspace_id: :string,
    assignee: :string,
    json: :boolean
  ]

  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    if opts[:labels] && mode == :text do
      IO.puts(
        :stderr,
        "bd2: warning: --labels is accepted for interface parity but the Issue resource has no labels field (ignored)."
      )
    end

    params =
      []
      |> put_if(:status, opts[:status])
      |> put_if(:issue_type, opts[:type])
      |> put_if(:priority, opts[:priority])
      |> put_if(:assignee, opts[:assignee])
      |> put_if(:workspace_id, opts[:workspace_id])

    case Client.get("/api/issues", params) do
      {:ok, %{"data" => issues}} -> Output.emit_issue_list(issues, mode)
      {:ok, other} -> Output.emit_issue_list(List.wrap(other), mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp put_if(list, _key, nil), do: list
  defp put_if(list, _key, ""), do: list
  defp put_if(list, key, value), do: list ++ [{key, value}]
end
