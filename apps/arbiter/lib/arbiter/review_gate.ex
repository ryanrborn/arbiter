defmodule Arbiter.ReviewGate do
  @moduledoc """
  Ash domain for durable, structured `Arbiter.Worker.ReviewGate` round outcomes
  (bd-aqyjuc).

  See `Arbiter.ReviewGate.Round` for the schema and rationale.
  """

  use Ash.Domain

  resources do
    resource Arbiter.ReviewGate.Round
  end
end
