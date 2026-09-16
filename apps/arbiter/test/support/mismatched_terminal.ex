defmodule Arbiter.Test.MismatchedTerminal do
  @moduledoc """
  A second, harmless `Arbiter.Sessions.Terminal` double — stands in for
  "whichever terminal `Stream.ensure_reader/2` happened to resolve before a
  real `attach/2` asks for `Arbiter.Test.ScriptedPty` by name" (bd-5pelo2
  round 4 finding 2). Every callback succeeds and does nothing, so a reader
  stuck on this terminal is inert rather than wrong in some other way — the
  only thing under test is whether `attach/2` replaces it.
  """

  @behaviour Arbiter.Sessions.Terminal

  @impl true
  def start_stream(_session, _path, _opts), do: {:ok, %{snapshot: "MISMATCHED"}}

  @impl true
  def stop_stream(_session, _opts), do: :ok

  @impl true
  def streaming?(_session, _opts), do: false

  @impl true
  def snapshot(_session, _opts), do: {:ok, "MISMATCHED"}

  @impl true
  def send_input(_session, _bytes, _opts), do: :ok

  @impl true
  def resize(_session, cols, rows, _opts) when is_integer(cols) and is_integer(rows), do: :ok

  @impl true
  def geometry(_session, _opts), do: {:ok, %{cols: 80, rows: 24, title: "mismatched"}}

  @impl true
  def alive?(_session, _opts), do: true
end
