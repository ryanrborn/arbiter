defmodule ArbiterCli.Cmd.Batch do
  @moduledoc """
  `arb batch <verb>` — the batch (vernacular: "convoy"/"Vanguard") resource.
  Group issues into a batch and manage its membership.

      arb batch list                            batches in the active workspace
      arb batch show   <batch-id>
      arb batch create <title> [--lifecycle system_managed|owned]
      arb batch add    <batch-id> <issue-id...>
      arb batch remove <batch-id> <issue-id>
      arb batch close  <batch-id> [--reason ...]

  In the default vernacular `batch` reads as "convoy", so `arb convoy create`
  resolves here. `rm` is accepted as an alias for `remove`.
  """

  alias ArbiterCli.{Client, Cmd, Output, Workspace}

  def run(argv) do
    case argv do
      ["list" | rest] -> list(rest)
      ["ls" | rest] -> list(rest)
      ["show" | rest] -> Cmd.Convoy.run(["show" | rest])
      ["create" | rest] -> Cmd.Convoy.run(["create" | rest])
      ["add" | rest] -> Cmd.Convoy.run(["add" | rest])
      ["remove" | rest] -> Cmd.Convoy.run(["remove" | rest])
      ["rm" | rest] -> Cmd.Convoy.run(["rm" | rest])
      ["close" | rest] -> Cmd.Convoy.run(["close" | rest])
      [] -> Output.die("batch requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown batch subcommand: #{unknown}", usage_hint())
    end
  end

  defp list(argv) do
    mode = Output.mode(argv)
    workspace_id = Workspace.id_or_halt()

    case Client.get("/api/convoys", workspace_id: workspace_id) do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text) do
    v = ArbiterCli.Vernacular.fetch()
    IO.puts("(no #{ArbiterCli.Vernacular.label(v, "batch")}s)")
  end

  defp emit_list(list, :text) do
    v = ArbiterCli.Vernacular.fetch()
    IO.puts("#{ArbiterCli.Vernacular.cap(v, "batch")}s (#{length(list)}):")

    Enum.each(list, fn c ->
      progress =
        case {c["closed_issues"], c["total_issues"]} do
          {closed, total} when is_integer(closed) and is_integer(total) -> "  #{closed}/#{total}"
          _ -> ""
        end

      IO.puts("  #{c["id"]}  [#{c["status"]}]  #{c["title"]}#{progress}")
    end)
  end

  defp usage_hint do
    "verbs: list, show, create, add, remove, close"
  end
end
