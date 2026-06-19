defmodule ArbiterCli.Cmd.Issue do
  @moduledoc """
  `arb issue <verb>` — the issue (vernacular: "bead") resource.

      arb issue list      [--status ...] [--type ...] [--priority ...]
                          [--labels ...] [--tracker]
      arb issue show      <id>
      arb issue create    <title> [--description ...] [--priority ...]
                          [--type ...] [--deps id1,id2] [--labels a,b]
                          [--parent <parent-id>] [--auto-close]
      arb issue update    <id> [--title ...] [--priority N] [--difficulty N]
                          [--status s] [--description d] [--assignee a]
                          [--append-notes text] [--qa-notes text]
                          [--deployment-notes text] [--pr-body text]
      arb issue close     <id> [--reason ...]
      arb issue reopen    <id>
      arb issue claim     <issue#> [--force] [--rig <rig>]
      arb issue sync      [--dry]
      arb issue ready
      arb issue dispatch  <id> [<rig>] [--with-claude] [--model <name>]

  In the default (Sith) vernacular `issue` reads as "bead" and `dispatch`
  reads as "sling", so `arb bead show <id>` and `arb sling <id>` resolve here.
  """

  alias ArbiterCli.Cmd
  alias ArbiterCli.Output
  alias ArbiterCli.Workspace

  def run(argv) do
    # A `--workspace <name>` flag anywhere in an `arb issue *` invocation
    # overrides the active workspace, exactly as `ARB_WORKSPACE` does. We
    # strip it here and seed the env so every subcommand below — each of
    # which resolves the workspace through `ARB_WORKSPACE` — honors it
    # uniformly, without each having to declare the switch itself.
    argv =
      case Workspace.take_flag(argv) do
        {nil, rest} ->
          rest

        {name, rest} ->
          System.put_env("ARB_WORKSPACE", name)
          rest
      end

    case argv do
      ["list" | rest] -> Cmd.List.run(rest)
      ["show" | rest] -> Cmd.Show.run(rest)
      ["create" | rest] -> Cmd.Create.run(rest)
      ["update" | rest] -> Cmd.Update.edit_issue(rest)
      ["close" | rest] -> Cmd.Close.run(rest)
      ["reopen" | rest] -> Cmd.Reopen.run(rest)
      ["claim" | rest] -> Cmd.Claim.run(rest)
      ["sync" | rest] -> Cmd.Sync.run(rest)
      ["ready" | rest] -> Cmd.Ready.run(rest)
      ["dispatch" | rest] -> Cmd.Sling.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("issue requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown issue subcommand: #{unknown}", usage_hint())
    end
  end

  defp usage_hint do
    "verbs: list, show, create, update, close, reopen, claim, sync, ready, dispatch"
  end
end
