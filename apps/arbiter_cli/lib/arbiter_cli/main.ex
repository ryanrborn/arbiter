defmodule ArbiterCli.Main do
  @moduledoc """
  Escript entry point. The CLI uses an `arb <resource> <verb>` grammar:
  the first token names a resource (or a flat meta command), the second the
  action on it.

  ## Resources

      arb issue list      [--status ...] [--type ...] [--priority ...] [--labels ...] [--tracker]
      arb issue show      <id>
      arb issue create    <title> [--description ...] [--priority ...] [--type ...]
                                  [--deps id1,id2] [--labels a,b] [--vanguard <batch-id>]
      arb issue update    <id> [--title ...] [--priority N] [--difficulty N] [--status s]
                                  [--description d] [--assignee a] [--append-notes text]
                                  [--qa-notes text] [--deployment-notes text]
      arb issue close     <id> [--reason ...]
      arb issue reopen    <id>
      arb issue claim     <issue#> [--force] [--rig <rig>]
      arb issue sync      [--dry]
      arb issue ready
      arb issue dispatch  <id> [<rig>] [--with-claude] [--model <name>]

      arb worker list
      arb worker show     <bead-id>
      arb worker log      <bead-id>
      arb worker stop     <bead-id>
      arb worker resume   <bead-id> [<rig>] [--model <name>]
      arb worker review   <bead-id> [--rig <rig>] [--model <name>]

      arb batch list
      arb batch show      <batch-id>
      arb batch create    <title> [--lifecycle system_managed|owned]
      arb batch add       <batch-id> <issue-id...>
      arb batch remove    <batch-id> <issue-id>
      arb batch close     <batch-id> [--reason ...]

      arb repo list
      arb repo show       <name>

      arb dep add         <from> <type> <to>
      arb dep remove      <from> <to>

      arb config get      [dotted.key] [--workspace W] [--json]
      arb config set      <dotted.key> <value> [--workspace W] [--force]
      arb config unset    <dotted.key> [--workspace W] [--force]

      arb server start    [--timeout SECONDS] [--json]
      arb server restart  [--timeout SECONDS] [--json]
      arb server deploy   [--timeout SECONDS] [--json] [--force]
      arb server migrate  [--json]
      arb server doctor   [--json]
      arb server version  [--json]

      arb workspace list
      arb workspace show  <id>

      arb message inbox   [--all | read <id> | clear | <bead-id>]
      arb message send    <recipient> <body> [--subject ...] [--directive bd-x] [--kind ...]
      arb message notify  [--limit N]

      arb usage show      [--by day|bead|campaign|workspace|rig|model|step|provider]
                                  [--since 7d|24h|<iso>] [--workspace <id>] [--limit N]
      arb usage events    [--bead <bead-id>] [--workspace <id>] [--step work|review]
                                  [--since ...] [--limit N]

      arb install cli     [--json]
      arb install service [--system] [--uninstall] [--json]

      arb mcp token mint  --tier coordinator [--workspace <id>] [--ttl <seconds>] [--json]
      arb mcp token verify <token> [--json]

  ## Meta commands (no resource)

      arb prime                Mission briefing — run at the start of a session
      arb where                Resolve the active workspace / paths
      arb init [path] [--force]
      arb version
      arb help

  ## Vernacular aliases

  Resources are neutral base terms; the active workspace's vernacular layers
  themed names on top as aliases. The default (Sith) vocabulary maps
  `worker → polecat`, `issue → bead`, `batch → convoy`, `repo → warship`, and
  `dispatch → sling`, so `arb polecat list`, `arb bead show <id>`,
  `arb convoy create …`, `arb warship list`, and `arb sling <id>` all resolve
  to their canonical counterparts. See `arb help vernacular`.

  ## Global flags

      --json     Emit machine-readable JSON (default is human-readable text)
      -h, --help Show usage

  ## Env

      ARB_HOST       Phoenix base URL (default http://127.0.0.1:4848)
      ARB_WORKSPACE  Workspace name to use (default "default")
  """

  @version "0.1.0"

  # Pre-`arb <resource> <verb>` flat commands, mapped to their new canonical
  # form. Each still runs (we dispatch to the new handler) but prints a
  # one-line note pointing at the new grammar. Themed names (`polecat`,
  # `convoy`, `warship`, `bead`, `sling`) are NOT here — they resolve through
  # the vernacular alias system and are not deprecated.
  @legacy %{
    "list" => {"issue", ["list"]},
    "show" => {"issue", ["show"]},
    "create" => {"issue", ["create"]},
    "close" => {"issue", ["close"]},
    "reopen" => {"issue", ["reopen"]},
    "claim" => {"issue", ["claim"]},
    "sync" => {"issue", ["sync"]},
    "ready" => {"issue", ["ready"]},
    "resume" => {"worker", ["resume"]},
    "review" => {"worker", ["review"]},
    "start" => {"server", ["start"]},
    "restart" => {"server", ["restart"]},
    "migrate" => {"server", ["migrate"]},
    "doctor" => {"server", ["doctor"]},
    "inbox" => {"message", ["inbox"]},
    "notify" => {"message", ["notify"]},
    "msg" => {"message", ["send"]},
    "warships" => {"repo", ["list"]},
    "install-cli" => {"install", ["cli"]},
    "install-service" => {"install", ["service"]}
  }

  def main(argv) do
    # Start :req's transitive applications. The escript bundles them but does
    # not auto-start. Without this, Req.get crashes with :finch not started.
    {:ok, _} = Application.ensure_all_started(:req)

    case argv do
      [] -> usage_and_exit(0)
      ["help" | rest] -> help(rest)
      ["-h"] -> usage_and_exit(0)
      ["--help"] -> usage_and_exit(0)
      ["-v"] -> IO.puts("arb #{@version}")
      ["--version"] -> IO.puts("arb #{@version}")
      [cmd | rest] -> dispatch(cmd, rest)
    end
  end

  defp dispatch(cmd, args) do
    case ArbiterCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args)

      {:unknown, suggestions} ->
        dispatch_legacy_or_unknown(cmd, args, suggestions)
    end
  end

  # An old flat command? Run its new form and point the user at it.
  defp dispatch_legacy_or_unknown(cmd, args, suggestions) do
    case legacy_redirect(cmd, args) do
      {:ok, canonical, new_args, new_form} ->
        IO.puts(:stderr, "arb: note: `arb #{cmd}` is now `arb #{new_form}` — running it for you.")
        dispatch_known(canonical, new_args)

      :none ->
        IO.puts(:stderr, "arb: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `arb help` for usage.")
        ArbiterCli.Output.halt(2)
    end
  end

  # `arb update` was dual-mode: an id edits an issue, a bare/flag-first call
  # deploys. Split it across the two new homes.
  defp legacy_redirect("update", args) do
    if deploy_invocation?(args) do
      {:ok, "server", ["deploy" | args], "server deploy"}
    else
      {:ok, "issue", ["update" | args], "issue update"}
    end
  end

  defp legacy_redirect(cmd, args) do
    case Map.fetch(@legacy, cmd) do
      {:ok, {resource, prefix}} ->
        {:ok, resource, prefix ++ args, "#{resource} #{Enum.join(prefix, " ")}"}

      :error ->
        :none
    end
  end

  # A bare verb, or one whose first token is a flag, is a deploy. The moment a
  # positional appears (the issue id) it's an edit.
  defp deploy_invocation?([]), do: true
  defp deploy_invocation?([first | _]), do: String.starts_with?(first, "-")

  defp dispatch_known("issue", args), do: ArbiterCli.Cmd.Issue.run(args)
  defp dispatch_known("worker", args), do: ArbiterCli.Cmd.Worker.run(args)
  defp dispatch_known("batch", args), do: ArbiterCli.Cmd.Batch.run(args)
  defp dispatch_known("repo", args), do: ArbiterCli.Cmd.Repo.run(args)
  defp dispatch_known("dep", args), do: ArbiterCli.Cmd.Dep.run(args)
  defp dispatch_known("config", args), do: ArbiterCli.Cmd.Config.run(args)
  defp dispatch_known("server", args), do: ArbiterCli.Cmd.Server.run(args)
  defp dispatch_known("workspace", args), do: ArbiterCli.Cmd.Workspace.run(args)
  defp dispatch_known("message", args), do: ArbiterCli.Cmd.Message.run(args)
  defp dispatch_known("usage", args), do: ArbiterCli.Cmd.Usage.run(args)
  defp dispatch_known("install", args), do: ArbiterCli.Cmd.Install.run(args)
  defp dispatch_known("mcp", args), do: ArbiterCli.Cmd.Mcp.run(args)
  # Top-level shortcut: `arb dispatch <id>` == `arb issue dispatch <id>`
  # (the Sith label "sling" aliases to it).
  defp dispatch_known("dispatch", args), do: ArbiterCli.Cmd.Issue.run(["dispatch" | args])
  defp dispatch_known("prime", args), do: ArbiterCli.Cmd.Prime.run(args)
  defp dispatch_known("where", args), do: ArbiterCli.Cmd.Where.run(args)
  defp dispatch_known("init", args), do: ArbiterCli.Cmd.Init.run(args)
  defp dispatch_known("version", args), do: ArbiterCli.Cmd.Version.run(args)
  defp dispatch_known("help", _args), do: usage_and_exit(0)

  # `arb help [vernacular]`
  defp help(["vernacular" | _]) do
    IO.puts(vernacular_help())
    emit_vernacular_verbs()
    ArbiterCli.Output.halt(0)
  end

  defp help(_), do: usage_and_exit(0)

  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    emit_vernacular_verbs()
    ArbiterCli.Output.halt(code)
  end

  @vernacular_help """
  Vernacular — themed vocabularies as aliases
  ===========================================

  Every resource has a neutral canonical name; the active workspace's
  vernacular maps a themed label onto it. Themed labels resolve to the
  canonical resource automatically (no per-alias config):

      canonical   default (Sith) label    example
      ---------   --------------------    -------------------------------
      worker      polecat                 arb polecat list  → arb worker list
      issue       bead                    arb bead show     → arb issue show
      batch       convoy                  arb convoy create → arb batch create
      repo        warship                 arb warship list  → arb repo list
      dispatch    sling                   arb sling <id>    → arb issue dispatch <id>

  ## The `sith` preset

  The full Sith lexicon is shipped as a named preset. Apply it to the global
  vernacular to theme prose and dashboards (Admiral, Acolyte, Directive,
  Strike Force, …) on top of the resource aliases above:

      {
        "coordinator": "Admiral",  "worker": "Acolyte",
        "issue": "Directive",      "batch": "Strike Force",
        "repo": "Warship",         "dispatch": "Sling",
        "merge_queue": "Reclamation", "monitor": "Inquisitor",
        "watchdog": "Grand Moff",  "epic": "Campaign"
      }

  PUT it to /api/settings/vernacular, or set it from the dashboard's
  vernacular editor. Any installation can opt into its own lexicon the same
  way; the canonical resource names never change.
  """

  defp vernacular_help, do: @vernacular_help

  # Surface the active workspace's vernacular command aliases so users see the
  # themed verbs they can type (e.g. `arb polecat` → `arb worker`). Silently
  # omitted when the workspace can't be reached and the defaults are empty.
  defp emit_vernacular_verbs do
    case ArbiterCli.AliasResolver.verb_aliases() do
      aliases when map_size(aliases) == 0 ->
        :ok

      aliases ->
        IO.puts("Vernacular aliases (active workspace):")

        aliases
        |> Enum.sort()
        |> Enum.each(fn {alias, canonical} ->
          IO.puts("    arb #{alias}  (alias for `arb #{canonical}`)")
        end)
    end
  end
end
