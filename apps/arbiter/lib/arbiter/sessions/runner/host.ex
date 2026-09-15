defmodule Arbiter.Sessions.Runner.Host do
  @moduledoc """
  The real `Arbiter.Sessions.Runner`: `Arbiter.Worker.ReleaseEnv.cmd/3`.

  Not a bare `System.cmd/3`, because the commands here start a tmux server
  which starts an agent CLI. Under the systemd OTP release `arbiter.service`
  exports `ROOTDIR` / `BINDIR` / `RELEASE_*`, every child inherits them, and
  anything that then boots a BEAM (`mix`, `elixir`, `arb`) resolves the
  release's ERTS instead of the pinned toolchain and dies with
  `cannot get bootfile` (bd-4hkzn3 / bd-2oelme). Running those commands is a
  session's whole purpose, so the scrub has to happen at the scope boundary —
  once, here — and is then inherited by the tmux server and every pane it opens.

  `ReleaseEnv.cmd/3` is also the only sanctioned way to spawn a non-pure tool
  in this repo; see `Arbiter.Worker.ReleaseEnvGuardTest`, whose inventory lists
  this file as the session path's single `:scrubbed` spawn site.
  """

  @behaviour Arbiter.Sessions.Runner

  alias Arbiter.Worker.ReleaseEnv

  @impl Arbiter.Sessions.Runner
  def run(command, args, opts) do
    {output, status} = ReleaseEnv.cmd(command, args, opts)
    {to_string(output), status}
  end
end
