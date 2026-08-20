defmodule ArbiterCli.Cmd.Doctor do
  @moduledoc """
  `arb doctor` — health checks.

  Currently runs:

    1. Can we reach `GET /api/workspaces`? (Phoenix reachable)
    2. Does at least one workspace exist? (DB reachable + reasonable state)
    3. Can we resolve the configured workspace? (ARB_WORKSPACE, else the
       workspace named "default", else the sole workspace if there's only one)
    4. Do any repos resolve? (zero repos means nothing can be dispatched)
    5. Do the CLI and server report the same version?
    6. Are database migrations up to date?

  Exit code 0 on all green, 1 on any failure.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.Cmd.Doctor.{Checks, Formatter}
  alias ArbiterCli.Output

  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn ->
      {_opts, _rest, mode} = ArgParser.parse(argv, switches: [])
      results = checks()

      case mode do
        :json -> Formatter.emit_json(results)
        :text -> Formatter.emit_text(results)
      end

      if Enum.any?(results, fn r -> r.status == :fail and r.fatal end) do
        Output.halt(1)
      end
    end)
  end

  @doc """
  Run every health check and return the result structs, in display order.
  Shared by `arb doctor` and `arb start` so "green" has one definition.
  """
  @spec checks() :: [Checks.Result.t()]
  def checks, do: Checks.run()

  @doc """
  True when Phoenix's HTTP API is reachable — the first health check on its
  own. This is the "is the stack already running?" signal `arb start` uses to
  stay a no-op.
  """
  @spec reachable?() :: boolean()
  def reachable?, do: Checks.phoenix().status == :ok

  @doc """
  True when every readiness-blocking health check passes. `fatal` alone can't
  gate this: it also drives `arb doctor`'s exit code, and some checks (like
  workspace resolution) are operator-actionable failures worth a non-zero
  exit without saying anything about whether the deployed server is healthy.
  `blocks_readiness` is the narrower signal `arb server deploy`'s
  auto-rollback wait actually needs.
  """
  @spec green?() :: boolean()
  def green? do
    Enum.all?(checks(), fn r ->
      r.status == :ok or (r.status == :fail and not r.blocks_readiness)
    end)
  end

  @doc """
  Print the human-readable health report to stdout and return whether all
  checks passed. Lets `arb start` show the same status block `arb doctor`
  does without duplicating the formatting.
  """
  @spec report() :: boolean()
  def report do
    results = checks()
    Formatter.emit_text(results)
    Enum.all?(results, fn r -> r.status == :ok end)
  end
end
