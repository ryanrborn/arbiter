defmodule Arbiter.Workers do
  @moduledoc """
  Ash domain for durable worker run history.

  An active worker is an ephemeral GenServer — once it stops, its state is
  gone. `Arbiter.Workers.Run` is the persistent record of what happened: who
  worked which bead, with what output, and how it ended. It survives node
  restarts and powers the "Completed Workers" view.

  See `Arbiter.Workers.Run` for the schema. The worker GenServer writes
  through this domain on init (status :running) and on terminal transitions
  (status :completed / :failed); writes are best-effort and never crash the
  worker.
  """

  use Ash.Domain

  resources do
    resource Arbiter.Workers.Run
  end
end
