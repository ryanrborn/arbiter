defmodule ArbiterCli.Cmd.Sync do
  @moduledoc """
  `arb sync [--dry] [--json]` — reconcile GitHub issues assigned to the
  workspace user against beads linked by `tracker_ref`. Two directions:

    * issue assigned + open + no bead → create a linked bead (as `claim`).
    * open bead with a github ref whose issue is unassigned/closed → close
      the bead.

  Flags:
    --dry    Print the plan without applying it.
    --json   Emit JSON instead of human-readable text.

  No-ops cleanly when the workspace's tracker isn't GitHub.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [dry: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      dry? = opts[:dry] || false

      workspace_id = Workspace.id_or_halt()

      request =
        if dry? do
          Client.get("/api/workspaces/#{workspace_id}/sync/plan")
        else
          Client.post("/api/workspaces/#{workspace_id}/sync", %{})
        end

      case request do
        {:ok, payload} -> emit(payload, dry?, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp emit(payload, _dry?, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, dry?, :text) do
    actions = payload["data"] || []
    results = payload["results"] || []

    case {actions, results} do
      {[], _} ->
        IO.puts(if dry?, do: "Sync plan: (no actions)", else: "Sync: nothing to do.")

      {_, _} ->
        header = if dry?, do: "Sync plan (#{length(actions)} action(s)):", else: "Sync:"
        IO.puts(header)

        if dry? or results == [] do
          Enum.each(actions, &print_action/1)
        else
          Enum.each(results, &print_result/1)
        end
    end
  end

  defp print_action(%{"action" => "create", "ref" => ref, "title" => title}) do
    IO.puts("  + create bead for ##{ref}: #{title}")
  end

  defp print_action(%{"action" => "close", "bead_id" => id, "reason" => reason}) do
    IO.puts("  - close #{id}: #{reason}")
  end

  defp print_action(other), do: IO.puts("  ? #{inspect(other)}")

  defp print_result(%{"outcome" => "created", "bead" => bead}) do
    IO.puts("  + created #{bead["id"]} (#{bead["tracker_type"]}:#{bead["tracker_ref"]})")
  end

  defp print_result(%{"outcome" => "closed", "bead" => bead}) do
    IO.puts("  - closed #{bead["id"]}")
  end

  defp print_result(%{"outcome" => "error", "action" => action, "reason" => reason}) do
    IO.puts("  ! error on #{inspect(action)}: #{reason}")
  end

  defp print_result(other), do: IO.puts("  ? #{inspect(other)}")
end
