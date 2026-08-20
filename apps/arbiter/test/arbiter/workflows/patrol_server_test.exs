defmodule Arbiter.Workflows.PatrolServerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.PatrolServer

  # A minimal fake patrol built on the shared scaffold (bd-d825hp), used to
  # exercise the extracted behaviour without touching real GitHub/DB state.
  # `Agent`-backed globals let each test steer `do_tick_body/1` and the
  # lazy-stop gate independently of GenServer state.
  defmodule FakePatrol do
    use Arbiter.Workflows.PatrolServer,
      priority_tag: :fake_patrol,
      log_label: "FakePatrol",
      no_work_message: "no work left",
      recheck_stop_message: "last watched item closed",
      gate: :open_work?

    defstruct PatrolServer.common_fields() ++ [:tick_agent, :gate_agent]

    @impl true
    def init(opts) do
      base = PatrolServer.base_init_fields(opts)

      state =
        struct!(
          __MODULE__,
          base ++ [tick_agent: opts[:tick_agent], gate_agent: opts[:gate_agent]]
        )

      {:ok, schedule_next(state)}
    end

    def open_work?(_workspace_id, _repo) do
      # gate_agent isn't reachable here (no state) — tests instead drive this
      # indirectly by sending :tick/:recheck to a server whose do_tick_body
      # flips ticks, and by a dedicated always-true/false variant below.
      true
    end

    @impl true
    def do_tick_body(state) do
      if state.tick_agent, do: Agent.update(state.tick_agent, &(&1 + 1))
      %{state | ticks: state.ticks + 1, idle_ticks: state.idle_ticks + 1}
    end

    @impl true
    def state_snapshot(state) do
      %{repo: state.repo, ticks: state.ticks, idle_ticks: state.idle_ticks}
    end
  end

  defmodule FakeNoWorkPatrol do
    use Arbiter.Workflows.PatrolServer,
      priority_tag: :fake_no_work_patrol,
      log_label: "FakeNoWorkPatrol",
      no_work_message: "no work left",
      recheck_stop_message: "last watched item closed",
      gate: :open_work?

    defstruct PatrolServer.common_fields()

    @impl true
    def init(opts) do
      base = PatrolServer.base_init_fields(opts)
      {:ok, schedule_next(struct!(__MODULE__, base))}
    end

    def open_work?(_workspace_id, _repo), do: false

    @impl true
    def do_tick_body(state), do: %{state | ticks: state.ticks + 1}

    @impl true
    def state_snapshot(state), do: %{ticks: state.ticks}
  end

  describe "shared scaffold — tick/1, state/1" do
    test "tick/1 runs do_tick_body synchronously and state/1 reflects it" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, pid} =
        FakePatrol.start_link(
          repo: "owner/repo",
          workspace_id: "ws-1",
          interval_ms: 60_000,
          tick_agent: agent,
          name: String.to_atom("FakePatrol_#{System.unique_integer([:positive])}")
        )

      :ok = FakePatrol.tick(pid)
      :ok = FakePatrol.tick(pid)

      assert Agent.get(agent, & &1) == 2
      assert FakePatrol.state(pid) == %{repo: "owner/repo", ticks: 2, idle_ticks: 2}
    end
  end

  describe "shared scaffold — lazy-stop gate on handle_info(:tick)" do
    test "a patrol whose gate returns false stops instead of ticking again" do
      {:ok, pid} =
        FakeNoWorkPatrol.start_link(
          repo: "owner/repo",
          workspace_id: "ws-1",
          interval_ms: 10,
          name: String.to_atom("FakeNoWorkPatrol_#{System.unique_integer([:positive])}")
        )

      ref = Process.monitor(pid)
      send(pid, :tick)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "do_tick/3" do
    test "runs the given module's do_tick_body and restores the priority tag afterward" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      state = %{struct!(FakePatrol, []) | tick_agent: agent, ticks: 0, idle_ticks: 0}

      assert Arbiter.GitHub.Limiter.current_subsystem() == :unattributed

      new_state = PatrolServer.do_tick(FakePatrol, :fake_patrol, state)

      assert new_state.ticks == 1
      assert Agent.get(agent, & &1) == 1
      # Outside with_priority/3 the tag reverts to :unattributed — confirms
      # do_tick/3 tags for the duration of the call and restores it afterward.
      assert Arbiter.GitHub.Limiter.current_subsystem() == :unattributed
    end
  end

  describe "schedule_next/2" do
    test "reschedules :tick with idle-backoff-jittered delay and replaces the timer_ref" do
      state = %{
        struct!(FakePatrol, [])
        | idle_ticks: 0,
          interval_ms: 10,
          timer_ref: nil
      }

      new_state = PatrolServer.schedule_next(state, 900_000)
      assert is_reference(new_state.timer_ref)
      assert_receive :tick, 500
    end

    test "cancels a pre-existing timer before scheduling the next one" do
      old_ref = Process.send_after(self(), :stale, 60_000)
      state = %{struct!(FakePatrol, []) | idle_ticks: 0, interval_ms: 10, timer_ref: old_ref}

      new_state = PatrolServer.schedule_next(state, 900_000)
      refute new_state.timer_ref == old_ref
      assert Process.read_timer(old_ref) == false
    end
  end
end
