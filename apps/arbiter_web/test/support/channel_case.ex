defmodule ArbiterWeb.ChannelCase do
  @moduledoc """
  Test case for `Phoenix.Channel`s (bd-3ymdvi, phase 4).

  Same sandbox discipline as `ArbiterWeb.ConnCase`, and for the same reason: a
  channel runs in its own process under the ExUnit test supervisor, so it can
  still be holding a checkout on the single shared sandbox connection when the
  test ends. Channel tests therefore run `async: false`, like the LiveView
  ones, and `Arbiter.DataCase.setup_sandbox/1` owns the teardown ordering.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ArbiterWeb.Endpoint

      import Phoenix.ChannelTest
      import ArbiterWeb.ChannelCase
    end
  end

  setup tags do
    Arbiter.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Swap an application env key for the duration of the test, restoring the
  previous value — including "was not set" — afterwards.

  Never `delete_env`: `config/test.exs` sets several of these deliberately and
  deleting one leaks the operator's real directories into a later test.
  """
  @spec put_env(atom(), term()) :: :ok
  def put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)

    :ok
  end
end
