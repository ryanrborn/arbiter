defmodule ArbiterCli.Cmd.Workspace do
  @moduledoc """
  `arb workspace <verb>` — create and inspect workspaces, manage secrets, and
  edit standing orders.

      arb workspace list                       all workspaces (name, prefix, id)
      arb workspace show <id>                  one workspace's detail incl. config
      arb workspace create <name>              create a new workspace
        [--prefix bd] [--tracker-type none] [--merger-strategy direct]
        [--description "..."]

      arb workspace standing-order ls          list this workspace's standing orders
      arb workspace standing-order add <text>  append one standing order
      arb workspace standing-order rm <index|text>
                                               remove one standing order (1-based
                                               index, or exact text match)

      All three accept `--repo <name>` to target a repo-scoped standing order
      (stored under `repo_paths.<repo>.standing_orders`) instead of the
      workspace-global list. The repo must already be registered in
      `repo_paths` (add its path first with
      `arb config set repo_paths.<repo>.path <path>`).
      `--rig <name>` is accepted as a deprecated alias for `--repo <name>`;
      if both are given, `--repo` wins.

      arb workspace secret ls                  names of the configured secrets
      arb workspace secret set <key> <value>   store/overwrite an encrypted secret
      arb workspace secret rm <key>            remove an encrypted secret

  Secrets are stored encrypted at rest (ash_cloak) and are never returned in
  plaintext — only their key names are shown. Reference one from workspace
  config with `credentials_ref: "secret:<key>"`, e.g.

      arb config set tracker.config.credentials_ref secret:tracker_token
      arb workspace secret set tracker_token sct_rw_...

  Standing orders live in `config.standing_orders` — a list of short imperative
  strings surfaced in `arb prime`, the **coordinator's** briefing. They are
  never injected into any worker prompt — put worker-facing instructions in
  the repo's `CLAUDE.md` instead. The `add`/`rm` verbs edit individual entries
  via `PATCH /api/workspaces/:id/config` so the rest of the config is never
  clobbered.

  All verbs accept `--workspace <name>` to target a workspace other than the
  default. Reads from `GET /api/workspaces`; writes via `PATCH /api/workspaces/:id`.

  For the full reference of every `workspace.config` key (tracker, merge,
  agent/review_agent, security, routing, review/review_gate, review_automation,
  quota, conductor, standing_orders, repo_paths, pr_patrol, review_patrol) with
  valid values and defaults, see `arb config schema` (also appended below).
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Output}
  alias ArbiterCli.Cmd.Workspace.{Secrets, StandingOrders}

  # Mirrors Arbiter.Tasks.Workspace.valid_tracker_types/0 and
  # valid_merger_strategies/0 for friendly client-side errors on `create`. The
  # server's ValidateConfig remains the source of truth.
  @valid_tracker_types ~w(none jira shortcut linear github gitlab)
  @valid_merger_strategies ~w(direct gitlab github)

  @switches [
    workspace: :string,
    repo: :string,
    rig: :string,
    json: :boolean,
    prefix: :string,
    description: :string,
    tracker_type: :string,
    merger_strategy: :string
  ]

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    case argv do
      ["list" | rest] ->
        list(rest)

      ["ls" | rest] ->
        list(rest)

      ["show" | rest] ->
        show(rest)

      ["create" | rest] ->
        create(rest)

      ["standing-order" | rest] ->
        StandingOrders.run(rest, switches: @switches)

      ["secret" | rest] ->
        Secrets.run(rest, switches: @switches)

      ["--help" | _] ->
        print_help()

      ["-h" | _] ->
        print_help()

      [] ->
        Output.die("workspace requires a subcommand", verbs())

      [unknown | _] ->
        Output.die("unknown workspace subcommand: #{unknown}", verbs())
    end
  end

  defp verbs, do: "verbs: list, show, create, standing-order, secret"

  defp print_help do
    IO.puts(@moduledoc)
    IO.puts("")
    IO.puts(ArbiterCli.ConfigSchema.render())
  end

  defp list(argv) do
    mode = Output.mode(argv)

    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    id =
      case rest do
        [id] -> id
        [] -> Output.die("workspace show requires a workspace id or name")
        _ -> Output.die("workspace show takes exactly one argument: the workspace id")
      end

    case Client.get("/api/workspaces/" <> id) do
      {:ok, ws} -> Output.emit_workspace(ws, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ----- create ----------------------------------------------------------

  # Pre-existing complexity 14 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp create(argv) do
    {opts, rest, mode} = ArgParser.parse(argv, switches: @switches)

    name =
      case rest do
        [name] -> name
        [] -> Output.die("workspace create requires a name", "arb workspace create <name>")
        _ -> Output.die("workspace create takes exactly one positional argument: the name")
      end

    if String.trim(name) == "", do: Output.die("workspace create: name must not be empty")

    prefix = opts[:prefix] || "bd"
    tracker_type = opts[:tracker_type] || "none"
    merger_strategy = opts[:merger_strategy] || "direct"

    unless tracker_type in @valid_tracker_types do
      Output.die(
        "workspace create: invalid --tracker-type #{inspect(tracker_type)}",
        "one of: #{Enum.join(@valid_tracker_types, ", ")}"
      )
    end

    unless merger_strategy in @valid_merger_strategies do
      Output.die(
        "workspace create: invalid --merger-strategy #{inspect(merger_strategy)}",
        "one of: #{Enum.join(@valid_merger_strategies, ", ")}"
      )
    end

    config = %{
      "tracker" => %{"type" => tracker_type},
      "merge" => %{"strategy" => merger_strategy}
    }

    body =
      %{"name" => name, "prefix" => prefix, "config" => config}
      |> maybe_put("description", opts[:description])

    case Client.post("/api/workspaces", body) do
      {:ok, ws} ->
        case mode do
          :json -> Output.emit_json(ws)
          :text -> IO.puts("created workspace #{ws["name"]} (#{ws["id"]}) prefix=#{ws["prefix"]}")
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_list(list, :json), do: Output.emit_json(%{"data" => list})

  defp emit_list([], :text) do
    IO.puts("(no workspaces)")
  end

  defp emit_list(list, :text) do
    IO.puts("Workspaces (#{length(list)}):")

    Enum.each(list, fn ws ->
      IO.puts("  #{ws["name"]}  prefix=#{ws["prefix"]}  id=#{ws["id"]}")
    end)
  end
end
