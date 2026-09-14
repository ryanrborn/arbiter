defmodule Arbiter.SandboxTeardownTest do
  @moduledoc """
  Regression test for bd-5scl0c.

  `Arbiter.DataCase`'s leaked-child sweep used to call
  `DynamicSupervisor.terminate_child/2` directly. `terminate_child/2` sends
  `Process.exit(child, :shutdown)`, which kills a child that does not trap
  exits *immediately* — including while it is parked inside a DB query or an
  `Ecto` transaction. DBConnection sees the holder ETS table transfer back to
  the pool, logs

      Exqlite.Connection (#PID<…>) disconnected:
        ** (DBConnection.ConnectionError) client #PID<…> exited

  disconnects the single (`pool_size: 1`) physical SQLite connection and stops
  the `DBConnection.Ownership.Proxy`. The test that owned that connection then
  loses it mid-run: every later query raises `DBConnection.OwnershipError`
  ("cannot find ownership process"), which call sites routinely swallow into a
  misleading `:not_found`, and in shared mode every other process in the VM
  loses DB access too.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.Workspace

  # A child that spends essentially all of its time inside a DB transaction,
  # i.e. holding a checkout on the sandbox connection. It does not trap exits,
  # so a bare `:shutdown` signal kills it mid-transaction.
  defmodule BusyDbChild do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(parent) do
      send(self(), :work)
      {:ok, parent}
    end

    @impl true
    def handle_info(:work, parent) do
      Arbiter.Repo.transaction(fn ->
        Arbiter.Repo.query!("SELECT 1")
        send(parent, :in_transaction)
        Process.sleep(20)
      end)

      send(self(), :work)
      {:noreply, parent}
    end
  end

  @sweep_supervisor Arbiter.Workflows.MachineSupervisor

  test "sweeping a leaked child that is mid-query leaves the sandbox connection intact" do
    {:ok, ws} = Ash.create(Workspace, %{name: "sandbox-teardown-ws", prefix: "stw"})

    {:ok, _child} =
      DynamicSupervisor.start_child(@sweep_supervisor, %{
        id: :sandbox_teardown_busy_child,
        start: {BusyDbChild, :start_link, [self()]},
        restart: :temporary
      })

    # Only sweep once the child is demonstrably inside a transaction, so the
    # sweep is guaranteed to land on a process holding the connection.
    assert_receive :in_transaction, 2_000

    log =
      capture_log(fn ->
        Arbiter.DataCase.stop_leaked_dynamic_children()
        # The disconnect is logged asynchronously by the connection process.
        Process.sleep(100)
      end)

    refute log =~ "client #PID",
           "the sweep killed a child that was holding the sandbox connection: #{log}"

    # The real damage: the owning test loses its sandbox connection entirely.
    assert {:ok, %Workspace{}} = Ash.get(Workspace, ws.id)
  end
end
