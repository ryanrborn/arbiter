defmodule Arbiter.ProcessTeardownTest do
  use ExUnit.Case, async: true

  alias Arbiter.ProcessTeardown

  defmodule Echo do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  setup do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :teardown_sup)
    {:ok, sup: sup}
  end

  test "removes a child from its supervisor", %{sup: sup} do
    {:ok, pid} = DynamicSupervisor.start_child(sup, %{id: :e, start: {Echo, :start_link, [[]]}})
    ref = Process.monitor(pid)

    assert ProcessTeardown.stop_child(sup, pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert DynamicSupervisor.which_children(sup) == []
  end

  # stop_child/3 suspends before it terminates. If the termination then does
  # not happen — wrong supervisor, already-detached child — the process must
  # not be left frozen: a suspended GenServer answers no calls at all, so it
  # would silently time out every caller for the rest of the run.
  test "resumes a child it could not terminate, instead of leaving it suspended", %{sup: sup} do
    {:ok, other} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, pid} = DynamicSupervisor.start_child(sup, %{id: :e, start: {Echo, :start_link, [[]]}})

    assert ProcessTeardown.stop_child(other, pid) == :ok

    assert Process.alive?(pid)
    assert GenServer.call(pid, :ping, 500) == :pong
  end

  test "is a no-op for an already-dead child", %{sup: sup} do
    {:ok, pid} = DynamicSupervisor.start_child(sup, %{id: :e, start: {Echo, :start_link, [[]]}})
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert ProcessTeardown.stop_child(sup, pid) == :ok
  end
end
