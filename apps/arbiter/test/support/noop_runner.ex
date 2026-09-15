defmodule Arbiter.Test.NoopRunner do
  @moduledoc """
  An `Arbiter.Sessions.Runner` that runs nothing and always succeeds.

  `Arbiter.Test.SessionRunnerStub` keeps its script and its recorded calls in
  the **caller's** process dictionary, which is exactly right when the caller
  is the test — and useless when the caller is a channel or a reader in its own
  process. Those tests do not need the argv (that is asserted in
  `Arbiter.Sessions.Terminal.TmuxTest` and phase 1's suite); they need
  `Arbiter.Sessions.kill/2` to reach its database effects without a real
  `systemctl --user stop` running on the host that is also running the live
  coordinator.
  """

  @behaviour Arbiter.Sessions.Runner

  @impl Arbiter.Sessions.Runner
  def run(_command, _args, _opts), do: {"", 0}
end
