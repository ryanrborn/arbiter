defmodule ArbiterCli.Cmd.List do
  @moduledoc """
  `arb list [--status ...] [--type ...] [--priority N] [--labels ...]
            [--tracker] [--workspace-id ID] [--assignee USER] [--json]`

  Filters are passed through to `GET /api/issues` as query params. `--labels`
  is accepted for interface parity with `bd`, but the current Issue resource
  has no labels field — the flag is ignored with a stderr warning.

  With `--tracker`, the workspace's external tracker is also queried (e.g.
  open GitHub issues assigned to the workspace user) and merged into the
  listing. Local tasks and tracker issues are deduplicated by `tracker_ref`
  — a tracker issue already represented by a task is shown as the task row
  and not duplicated. Unclaimed tracker issues are visually distinct (no
  task id, prefixed with `(unclaimed)`).

  If the workspace's tracker doesn't support listing (e.g. `:none`), the
  flag is a no-op and we emit a stderr notice but still print the local
  tasks — the CLI degrades cleanly rather than failing.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [
    status: :string,
    type: :string,
    priority: :integer,
    labels: :string,
    workspace_id: :string,
    assignee: :string,
    tracker: :boolean,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      if opts[:labels] && mode == :text do
        IO.puts(
          :stderr,
          "arb: warning: --labels is accepted for interface parity but the Issue resource has no labels field (ignored)."
        )
      end

      params =
        []
        |> put_if(:status, opts[:status])
        |> put_if(:issue_type, opts[:type])
        |> put_if(:priority, opts[:priority])
        |> put_if(:assignee, opts[:assignee])
        |> put_if(:workspace_id, opts[:workspace_id])

      with {:ok, tasks} <- fetch_tasks(params) do
        if opts[:tracker] do
          emit_with_tracker(tasks, mode)
        else
          Output.emit_issue_list(tasks, mode)
        end
      else
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp fetch_tasks(params) do
    case Client.get("/api/issues", params) do
      {:ok, %{"data" => issues}} -> {:ok, issues}
      {:ok, other} -> {:ok, List.wrap(other)}
      {:error, _} = err -> err
    end
  end

  defp emit_with_tracker(tasks, mode) do
    workspace_id = Workspace.id_or_halt()

    case Client.get("/api/workspaces/#{workspace_id}/tracker/issues") do
      {:ok, %{"supported" => true, "data" => issues}} ->
        emit_combined(tasks, issues, mode)

      {:ok, %{"supported" => false}} ->
        if mode == :text do
          IO.puts(
            :stderr,
            "arb: notice: workspace tracker doesn't support listing — showing local tasks only."
          )
        end

        emit_combined(tasks, [], mode)

      {:ok, _unexpected} ->
        emit_combined(tasks, [], mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp emit_combined(tasks, tracker_issues, mode) do
    task_refs =
      tasks
      |> Enum.map(& &1["tracker_ref"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> MapSet.new()

    unclaimed = Enum.reject(tracker_issues, &MapSet.member?(task_refs, &1["ref"]))

    case mode do
      :json ->
        IO.puts(
          Jason.encode!(%{
            data: tasks,
            tracker_issues: Enum.map(unclaimed, &Map.put(&1, "unclaimed", true))
          })
        )

      :text ->
        emit_text_combined(tasks, unclaimed)
    end
  end

  defp emit_text_combined([], []) do
    IO.puts("(no issues)")
  end

  defp emit_text_combined(tasks, unclaimed) do
    Enum.each(tasks, fn task -> IO.puts(Output.format_issue_line(task)) end)

    if unclaimed != [] do
      Enum.each(unclaimed, fn issue ->
        IO.puts(format_unclaimed_line(issue))
      end)
    end
  end

  # Format mirrors the task line shape so the columns line up, but with an
  # `(unclaimed)` marker in the id slot and the tracker ref where the
  # priority would be — these rows don't *have* a task id or priority yet.
  defp format_unclaimed_line(issue) do
    id = String.pad_trailing("(unclaimed)", 12)
    status = "[#{issue["status"] || "open"}]" |> String.pad_trailing(14)
    ref = "##{issue["ref"]}"
    title = issue["title"] || ""
    "#{id}#{status} #{ref}  #{title}"
  end

  defp put_if(list, _key, nil), do: list
  defp put_if(list, _key, ""), do: list
  defp put_if(list, key, value), do: list ++ [{key, value}]
end
