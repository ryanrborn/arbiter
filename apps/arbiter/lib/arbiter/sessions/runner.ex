defmodule Arbiter.Sessions.Runner do
  @moduledoc """
  The one place session control operations reach the operating system
  (bd-bpt0ag, phase 1 of `docs/browser-hosted-coordinator-sessions.md`).

  Every session operation — launch, kill, enumerate — is a **synchronous
  shell-out that returns**: it runs `systemd-run` / `tmux` / `systemctl`,
  collects the output, and hands back `{output, exit_status}`. Nothing is
  retained. That is the deliberate opposite of `Port.open`, which would leave
  the BEAM owning a handle on the child, and it is what makes RFC §4.3's claim
  ("Arbiter holds no long-lived handle to the PTY") a property of the code
  rather than a promise — see `Arbiter.Sessions.NoPtyHandleTest`.

  Being a behaviour makes it the test seam as well: `Arbiter.Sessions` takes a
  `:runner` option, so the lifecycle logic is exercised against a scripted
  `systemctl` / `tmux` without a systemd user manager in sight
  (`Arbiter.Test.SessionRunnerStub`).

  ## Resolution order

  `Arbiter.Sessions.runner/1`: the `:runner` option, then
  `config :arbiter, :sessions_runner`, then `Arbiter.Sessions.Runner.Host`.
  """

  @doc """
  Run `command` with `args` and return `{collected_output, exit_status}`.

  Implementations MUST be synchronous and MUST NOT retain anything about the
  child process after returning. `opts` carries `System.cmd/3` options —
  `:env` and `:stderr_to_stdout` are the two `Arbiter.Sessions` passes.
  """
  @callback run(command :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {String.t(), non_neg_integer()}
end
