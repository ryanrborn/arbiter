defmodule Arbiter.Polecats do
  @moduledoc """
  Ash domain for durable polecat run history.

  An active polecat is an ephemeral GenServer — once it stops, its state is
  gone. `Arbiter.Polecats.Run` is the persistent record of what happened: who
  worked which bead, with what output, and how it ended. It survives node
  restarts and powers the "Completed Acolytes" view.

  See `Arbiter.Polecats.Run` for the schema. The polecat GenServer writes
  through this domain on init (status :running) and on terminal transitions
  (status :completed / :failed); writes are best-effort and never crash the
  polecat.
  """

  use Ash.Domain

  resources do
    resource(Arbiter.Polecats.Run)
  end
end
