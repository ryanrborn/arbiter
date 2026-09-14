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

  # `quiesce/2` only makes sense for a process with an OTP `sys` loop. A `Task`
  # is a `proc_lib` process without one, so `:sys.suspend` on it blocks for the
  # whole timeout and then exits — the caller pays the full budget for nothing.
  #
  # The `$initial_call` *dictionary* entry cannot tell the two apart: `Task`
  # writes the user's own MFA there (`Task.Supervised.get_initial_call/1`), the
  # same shape a `GenServer` gets, and it writes it from inside the new process
  # so it is not even there yet at spawn. `Process.info(pid, :initial_call)` is
  # set by the VM at spawn and is `{:proc_lib, :init_p, 5}` for every OTP
  # behaviour and `{Task.Supervised, _, _}` for a Task.
  test "returns immediately for a Task instead of waiting out the timeout" do
    task = Task.async(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(task.pid, :kill) end)

    # Wait out the Task's own startup so this measures classification, not the
    # race against the dictionary entry being written.
    assert await_initial_call_in_dictionary(task.pid)

    {micros, :ok} = :timer.tc(fn -> ProcessTeardown.quiesce(task.pid, 500) end)

    assert div(micros, 1000) < 100
  end

  test "returns immediately for a plain spawned process with no sys loop" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    {micros, :ok} = :timer.tc(fn -> ProcessTeardown.quiesce(pid, 500) end)

    assert div(micros, 1000) < 100
  end

  # The counterpart guard: narrowing the classification must not stop it
  # recognising real OTP behaviours, or the whole fix silently stops working.
  # `Agent` is in here on purpose — it is a `gen_server` whose `$initial_call`
  # dictionary entry is an anonymous fun, so only the VM-level `:initial_call`
  # classifies it correctly.
  test "still suspends OTP behaviours", %{sup: sup} do
    {:ok, gen_server} =
      DynamicSupervisor.start_child(sup, %{id: :e, start: {Echo, :start_link, [[]]}})

    {:ok, agent} = Agent.start(fn -> :state end)
    on_exit(fn -> Process.exit(agent, :kill) end)

    for pid <- [gen_server, agent] do
      assert ProcessTeardown.quiesce(pid, 500) == :ok
      # A suspended process handles no ordinary messages at all.
      assert catch_exit(GenServer.call(pid, :ping, 100))
      :sys.resume(pid)
    end

    assert GenServer.call(gen_server, :ping, 500) == :pong
  end

  defp await_initial_call_in_dictionary(pid, attempts \\ 200) do
    case Process.info(pid, {:dictionary, :"$initial_call"}) do
      {{:dictionary, :"$initial_call"}, nil} when attempts > 0 ->
        Process.sleep(1)
        await_initial_call_in_dictionary(pid, attempts - 1)

      {{:dictionary, :"$initial_call"}, mfa} ->
        mfa != nil

      _ ->
        false
    end
  end
end
