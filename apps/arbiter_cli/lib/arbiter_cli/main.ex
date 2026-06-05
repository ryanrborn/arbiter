defmodule ArbiterCli.Main do
  @moduledoc """
  Escript entry point. Dispatches the first argument to a subcommand module
  under `ArbiterCli.Cmd.*`.

  Subcommands:

      arb init [path] [--force]
      arb show <id>
      arb create <title> [--description ...] [--priority ...] [--type ...]
                         [--deps id1,id2] [--labels a,b] [--vanguard <convoy-id>]
      arb close <id> [--reason ...]
      arb reopen <id>
      arb list [--status ...] [--type ...] [--priority ...] [--labels ...]
                [--tracker]    Also list open assigned issues from the workspace's
                               external tracker (visually distinct, deduped by ref).
      arb update <id> [--priority ...] [--append-notes ...]
                               Edit an issue's fields.
      arb update [--timeout SECONDS] [--json]
                               No id: deploy. git pull --ff-only main, then
                               restart Phoenix so merged code is live.
      arb convoy create <title> [--lifecycle system_managed|owned]
      arb convoy add <convoy-id> <issue-id...>
      arb convoy rm <convoy-id> <issue-id>
      arb convoy show <convoy-id>
      arb convoy close <convoy-id> [--reason ...]
                       Group directives into a batch (vernacular: "Vanguard").
      arb dep add <from> <type> <to>
      arb dep rm <from> <to>
      arb ready
      arb doctor
      arb start [--timeout SECONDS] [--json]
      arb restart [--timeout SECONDS] [--json]
      arb install-service [--system] [--uninstall] [--json]
                               Install a systemd unit so the stack starts at
                               boot (ExecStart=arb start). --uninstall removes it.
      arb where
      arb prime
      arb sling <bead-id>
      arb review <bead-id> [--rig <rig>] [--model <name>]
                               Dispatch a review-only acolyte against the
                               PR/MR linked to a bead. No worktree, no branch,
                               no merge.
      arb polecat show <bead-id>
      arb polecat stop <bead-id>
      arb inbox [--all | read <id> | clear | <bead-id>]
      arb notify [--limit N]
      arb message <bead-id> <text>
      arb msg <recipient> <body> [--subject ...] [--directive bd-x] [--kind ...]
      arb claim <issue#> [--force] [--rig <rig>]
      arb sync [--dry]
      arb usage [--by day|bead|campaign|workspace|rig|model|step|provider]
                [--since 7d|24h|<iso>] [--workspace <id>] [--limit N]
      arb usage events [--bead <bead-id>] [--workspace <id>] [--step work|review]
                       [--since ...] [--limit N]
      arb config get   [dotted.key] [--workspace W] [--json]
      arb config set   <dotted.key> <value> [--workspace W] [--force]
      arb config unset <dotted.key>         [--workspace W] [--force]

  Global flags:
      --json     Emit machine-readable JSON (default is human-readable text)
      -h, --help Show usage

  Env:
      ARB_HOST       Phoenix base URL (default http://127.0.0.1:4848)
      ARB_WORKSPACE  Workspace name to use (default "default")
  """

  @version "0.1.0"

  def main(argv) do
    # Start :req's transitive applications. The escript bundles them but does
    # not auto-start. Without this, Req.get crashes with :finch not started.
    {:ok, _} = Application.ensure_all_started(:req)

    case argv do
      [] -> usage_and_exit(0)
      ["help"] -> usage_and_exit(0)
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
        IO.puts(:stderr, "arb: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `arb help` for usage.")
        ArbiterCli.Output.halt(2)
    end
  end

  defp dispatch_known("init", args), do: ArbiterCli.Cmd.Init.run(args)
  defp dispatch_known("show", args), do: ArbiterCli.Cmd.Show.run(args)
  defp dispatch_known("create", args), do: ArbiterCli.Cmd.Create.run(args)
  defp dispatch_known("close", args), do: ArbiterCli.Cmd.Close.run(args)
  defp dispatch_known("reopen", args), do: ArbiterCli.Cmd.Reopen.run(args)
  defp dispatch_known("list", args), do: ArbiterCli.Cmd.List.run(args)
  defp dispatch_known("update", args), do: ArbiterCli.Cmd.Update.run(args)
  defp dispatch_known("dep", args), do: ArbiterCli.Cmd.Dep.run(args)
  defp dispatch_known("ready", args), do: ArbiterCli.Cmd.Ready.run(args)
  defp dispatch_known("doctor", args), do: ArbiterCli.Cmd.Doctor.run(args)
  defp dispatch_known("start", args), do: ArbiterCli.Cmd.Start.run(args)
  defp dispatch_known("restart", args), do: ArbiterCli.Cmd.Restart.run(args)
  defp dispatch_known("install-service", args), do: ArbiterCli.Cmd.InstallService.run(args)
  defp dispatch_known("where", args), do: ArbiterCli.Cmd.Where.run(args)
  defp dispatch_known("sling", args), do: ArbiterCli.Cmd.Sling.run(args)
  defp dispatch_known("review", args), do: ArbiterCli.Cmd.Review.run(args)
  defp dispatch_known("prime", args), do: ArbiterCli.Cmd.Prime.run(args)
  defp dispatch_known("polecat", args), do: ArbiterCli.Cmd.Polecat.run(args)
  defp dispatch_known("inbox", args), do: ArbiterCli.Cmd.Inbox.run(args)
  defp dispatch_known("notify", args), do: ArbiterCli.Cmd.Notify.run(args)
  defp dispatch_known("message", args), do: ArbiterCli.Cmd.Message.run(args)
  defp dispatch_known("msg", args), do: ArbiterCli.Cmd.Msg.run(args)
  defp dispatch_known("claim", args), do: ArbiterCli.Cmd.Claim.run(args)
  defp dispatch_known("sync", args), do: ArbiterCli.Cmd.Sync.run(args)
  defp dispatch_known("usage", args), do: ArbiterCli.Cmd.Usage.run(args)
  defp dispatch_known("convoy", args), do: ArbiterCli.Cmd.Convoy.run(args)
  defp dispatch_known("config", args), do: ArbiterCli.Cmd.Config.run(args)
  defp dispatch_known("warships", args), do: ArbiterCli.Cmd.Warships.run(args)
  defp dispatch_known("help", _args), do: usage_and_exit(0)

  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    emit_vernacular_verbs()
    ArbiterCli.Output.halt(code)
  end

  # Surface the active workspace's vernacular command aliases so `arb help`
  # reflects the verbs the user can actually type (e.g. `arb dispatch` when
  # vernacular maps sling -> "Dispatch"). Silently omitted when the workspace
  # can't be reached or has no aliases — help must still work offline.
  defp emit_vernacular_verbs do
    case ArbiterCli.AliasResolver.verb_aliases() do
      aliases when map_size(aliases) == 0 ->
        :ok

      aliases ->
        IO.puts("Vernacular verbs (active workspace):")

        aliases
        |> Enum.sort()
        |> Enum.each(fn {alias, canonical} ->
          IO.puts("    arb #{alias}  (alias for `arb #{canonical}`)")
        end)
    end
  end
end
