defmodule GtElixirCli.Output.Halt do
  @moduledoc """
  Raised by `GtElixirCli.Output.halt/1` (and `die/*`) when the
  `:bd2_halt_strategy` process flag is set to `:raise`. Used in tests so the
  exit path is observable without actually killing the BEAM.
  """
  defexception [:code, message: "bd2 halt"]

  @impl true
  def exception(opts) do
    code = Keyword.fetch!(opts, :code)
    %__MODULE__{code: code, message: "bd2 halt (code=#{code})"}
  end
end
