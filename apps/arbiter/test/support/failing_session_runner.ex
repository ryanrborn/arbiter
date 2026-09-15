defmodule Arbiter.Test.FailingSessionRunner do
  @moduledoc """
  An `Arbiter.Sessions.Runner` whose every command fails.

  The counterpart to `Arbiter.Test.NoopRunner`, and for the same reason: a
  caller in its own process (a LiveView, a channel) cannot be handed
  `Arbiter.Test.SessionRunnerStub`'s script, which lives in the *calling*
  process's dictionary. This is how a test makes `Arbiter.Sessions.launch/1`
  fail the way a missing `systemd-run` would, so the UI's failure path is
  exercised rather than assumed.
  """

  @behaviour Arbiter.Sessions.Runner

  @impl Arbiter.Sessions.Runner
  def run(command, _args, _opts), do: {"#{command}: No such file or directory", 127}
end
