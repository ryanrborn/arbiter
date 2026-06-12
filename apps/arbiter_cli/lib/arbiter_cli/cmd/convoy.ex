defmodule ArbiterCli.Cmd.Convoy do
  @moduledoc """
  Convoy (vernacular: "Vanguard") subcommand router — group directives into a
  batch and manage its membership without raw SQL.

      arb convoy create <title> [--lifecycle system_managed|owned]
      arb convoy add    <convoy-id> <issue-id...>
      arb convoy rm     <convoy-id> <issue-id>
      arb convoy show   <convoy-id>
      arb convoy close  <convoy-id> [--reason ...]

  Output uses the active workspace's vernacular noun for "batch" (e.g. prints
  "Vanguard", not "convoy"). `create` targets the resolved workspace (see
  `ArbiterCli.Workspace`).

  Membership add/remove are idempotent: re-adding an existing member or
  removing an absent one succeeds and reprints the current state.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["create" | rest] -> create(rest, mode)
        ["add" | rest] -> add(rest, mode)
        ["rm" | rest] -> rm(rest, mode)
        ["remove" | rest] -> rm(rest, mode)
        ["show" | rest] -> show(rest, mode)
        ["close" | rest] -> close(rest, mode)
        [] -> Output.die("convoy requires a subcommand: create, add, rm, show, or close")
        [unknown | _] -> Output.die("unknown convoy subcommand: #{unknown}")
      end
    end
  end

  defp create(args, mode) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [lifecycle: :string, json: :boolean])

    title =
      case positional do
        [t] -> t
        [] -> Output.die("convoy create requires a title argument")
        many -> Enum.join(many, " ")
      end

    workspace_id = Workspace.id_or_halt()

    payload =
      %{"title" => title, "workspace_id" => workspace_id}
      |> maybe_put("lifecycle", opts[:lifecycle])

    case Client.post("/api/convoys", payload) do
      {:ok, convoy} -> Output.emit_convoy(convoy, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp add(args, mode) do
    case args do
      [convoy_id | [_ | _] = issue_ids] ->
        # Attach each in turn; the last response carries the full membership.
        convoy =
          Enum.reduce(issue_ids, nil, fn issue_id, _acc ->
            case Client.post("/api/convoys/" <> convoy_id <> "/members", %{
                   "issue_id" => issue_id
                 }) do
              {:ok, convoy} -> convoy
              {:error, err} -> Output.die(err)
            end
          end)

        Output.emit_convoy(convoy, mode)

      _ ->
        Output.die("convoy add requires: <convoy-id> <issue-id...>")
    end
  end

  defp rm(args, mode) do
    case args do
      [convoy_id, issue_id] ->
        case Client.delete("/api/convoys/" <> convoy_id <> "/members/" <> issue_id) do
          {:ok, convoy} -> Output.emit_convoy(convoy, mode)
          {:error, err} -> Output.die(err)
        end

      _ ->
        Output.die("convoy rm requires: <convoy-id> <issue-id>")
    end
  end

  defp show(args, mode) do
    case args do
      [convoy_id] ->
        case Client.get("/api/convoys/" <> convoy_id) do
          {:ok, convoy} -> Output.emit_convoy(convoy, mode)
          {:error, err} -> Output.die(err)
        end

      [] ->
        Output.die("convoy show requires a convoy id")

      _ ->
        Output.die("convoy show takes exactly one argument: the convoy id")
    end
  end

  defp close(args, mode) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [reason: :string, json: :boolean])

    case positional do
      [convoy_id] ->
        body = if opts[:reason], do: %{"reason" => opts[:reason]}, else: %{}

        case Client.post("/api/convoys/" <> convoy_id <> "/close", body) do
          {:ok, convoy} -> Output.emit_convoy(convoy, mode)
          {:error, err} -> Output.die(err)
        end

      _ ->
        Output.die("convoy close requires exactly one argument: the convoy id")
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
