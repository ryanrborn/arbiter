defmodule ArbiterCli.Cmd.Worker do
  @moduledoc """
  `arb worker <verb>` — the worker resource.

      arb worker list             active workers with status + step
      arb worker show   <bead-id> full snapshot incl. recent Claude output
      arb worker log    <bead-id> full uncapped durable transcript (audit)
      arb worker stop   <bead-id> terminate a running worker cleanly
      arb worker resume <bead-id> [<rig>] [--model <name>]
                                  re-attach a fresh agent to a stopped
                                  worker's preserved worktree
      arb worker review <bead-id> [--rig <rig>] [--model <name>]
                                  dispatch a review-only worker against the
                                  PR/MR linked to a bead

  Use `arb issue dispatch <id>` to start a worker in the first place.
  """

  alias ArbiterCli.Cmd
  alias ArbiterCli.Output

  def run(argv) do
    case argv do
      ["list" | _] -> Cmd.Polecat.run(argv)
      ["ls" | _] -> Cmd.Polecat.run(argv)
      ["show" | _] -> Cmd.Polecat.run(argv)
      ["log" | _] -> Cmd.Polecat.run(argv)
      ["stop" | _] -> Cmd.Polecat.run(argv)
      ["resume" | rest] -> Cmd.Resume.run(rest)
      ["review" | rest] -> Cmd.Review.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("worker requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown worker subcommand: #{unknown}", usage_hint())
    end
  end

  defp usage_hint do
    "verbs: list, show, log, stop, resume, review"
  end
end
