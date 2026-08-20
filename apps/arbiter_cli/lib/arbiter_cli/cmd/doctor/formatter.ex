defmodule ArbiterCli.Cmd.Doctor.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb doctor`.
  """

  alias ArbiterCli.{Client, Output}

  def emit_text(results) do
    IO.puts("arb doctor — checks against #{Client.base_url()}")
    IO.puts("")

    Enum.each(results, fn r ->
      marker = if r.status == :ok, do: "[ ok ]", else: "[fail]"
      IO.puts("#{marker} #{r.name}")
      if r.detail, do: IO.puts("        #{r.detail}")
      if r.status == :fail and r.hint, do: IO.puts("        hint: #{r.hint}")
    end)
  end

  def emit_json(results) do
    payload = %{
      base_url: Client.base_url(),
      checks: Enum.map(results, &Map.from_struct/1),
      ok: Enum.all?(results, fn r -> r.status == :ok end)
    }

    Output.emit_json(payload)
  end
end
