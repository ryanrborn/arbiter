defmodule Arbiter.Board.AutopilotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  # A board with one promotable card, as `Snapshot.derive/1` would return it.
  defp board(promote, paused? \\ false) do
    %{
      ready: [
        %{id: "bd-1", state: :next, reason: "next up — dispatching...", card: %{id: "bd-1"}}
      ],
      running: [],
      waiting: [],
      closed_today: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  # Start an autopilot that never ticks on its own — every test drives it by
  # hand so there is no race between the timer and the assertion.
  defp start(opts) do
    test = self()

    # Check if the test wants to use the real default_dispatch (for testing with mocks)
    use_real_dispatch = Keyword.get(opts, :use_real_dispatch, false)
    opts = Keyword.delete(opts, :use_real_dispatch)

    defaults = [
      name: nil,
      interval_ms: :never,
      debounce_ms: 20,
      topics: [],
      snapshot: fn opts -> board("bd-1", opts[:paused]) end
    ]

    # Only include the mock dispatch if not using the real one
    defaults =
      if use_real_dispatch do
        defaults
      else
        defaults ++
          [dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end]
      end

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  # Waits for any in-flight dispatch (including one an immediate follow-up
  # pass started on its own) to finish, so a test can drive a deterministic
  # next step instead of racing the autopilot's own background activity.
  defp await_idle(pid, tries \\ 200) do
    case :sys.get_state(pid) do
      %{dispatching: nil} ->
        :ok

      _ when tries > 0 ->
        Process.sleep(2)
        await_idle(pid, tries - 1)

      _ ->
        flunk("autopilot never returned to idle")
    end
  end

  describe "promotion" do
    test "dispatches the card the scheduler promoted" do
      pid = start(paused: false)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_receive {:dispatched, "bd-1"}
    end

    test "default_dispatch passes start_claude: true" do
      test = self()

      # Use :meck to stub Arbiter.Worker.Dispatch.dispatch/2 and capture its arguments.
      # This allows us to verify that default_dispatch/1 calls it with start_claude: true.
      :meck.new(Arbiter.Worker.Dispatch, [:passthrough])

      :meck.expect(Arbiter.Worker.Dispatch, :dispatch, fn task_id, opts ->
        send(test, {:dispatch_opts, opts})
        {:ok, %{task_id: task_id}}
      end)

      # Start without passing dispatch, so Autopilot uses the real default_dispatch/1.
      # That function will call Dispatch.dispatch/2, which we've stubbed with meck above.
      # Pass use_real_dispatch: true to signal that the start() helper should not
      # provide its default mock dispatch.
      pid = start(paused: false, use_real_dispatch: true)
      Autopilot.tick(pid)

      assert_receive {:dispatch_opts, opts}
      assert opts[:start_claude] == true

      :meck.unload(Arbiter.Worker.Dispatch)
    end

    test "dispatches nothing when the scheduler promotes nothing" do
      pid = start(paused: false, snapshot: fn _ -> board(nil) end)

      assert :idle = Autopilot.tick(pid)
      refute_receive {:dispatched, _}
    end

    test "a failed dispatch neither crashes the autopilot nor retries in the same tick" do
      pid = start(paused: false, dispatch: fn _ -> {:error, :no_repo} end)

      assert {:error, :no_repo} = Autopilot.tick(pid)
      assert Process.alive?(pid)
    end
  end

  describe "escalating a stuck card (bd-a40f4q)" do
    # `:ambiguous_repo` (and its siblings `:no_repo_configured`,
    # `:repo_not_found`) is deterministic — retrying dispatch never changes
    # the answer — so it escalates on the very first failure rather than
    # waiting for a retry budget to exhaust.
    test "a deterministic dispatch error escalates on the first failure" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn _ -> {:error, {:ambiguous_repo, ["tonic", "tonic_device"]}} end,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      Autopilot.tick(pid)

      assert_receive {:escalated, "bd-1", {:ambiguous_repo, ["tonic", "tonic_device"]}, 1}
    end

    # A repeat of the identical error on the same card is not fresh news —
    # escalating on every tick would flood the coordinator's inbox with a page
    # for a card that already has one outstanding.
    test "the same card failing the same way again does not re-escalate" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn _ -> {:error, :no_repo_configured} end,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      Autopilot.tick(pid)
      Autopilot.tick(pid)
      Autopilot.tick(pid)

      assert_receive {:escalated, "bd-1", :no_repo_configured, 1}
      refute_receive {:escalated, _, _, _}
    end

    # An error shape with no known deterministic classification (a network
    # blip, a quota gate) gets a retry budget before Autopilot pages a human —
    # it might just resolve on its own.
    test "a non-deterministic error only escalates after repeated failures" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn _ -> {:error, :timeout} end,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      Autopilot.tick(pid)
      refute_receive {:escalated, _, _, _}, 50

      Autopilot.tick(pid)
      refute_receive {:escalated, _, _, _}, 50

      Autopilot.tick(pid)
      assert_receive {:escalated, "bd-1", :timeout, _attempts}
    end

    # A successful dispatch clears whatever failure history the card had, so
    # a later, unrelated failure gets its own fresh escalation rather than
    # being silently swallowed by a stale latch.
    test "a successful dispatch resets the failure count for that card" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      dispatch_fun = fn _ ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> {:error, :no_repo_configured}
          1 -> {:ok, %{task_id: "bd-1"}}
          _ -> {:error, :no_repo_configured}
        end
      end

      pid =
        start(
          paused: false,
          dispatch: dispatch_fun,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      Autopilot.tick(pid)
      assert_receive {:escalated, "bd-1", :no_repo_configured, 1}

      assert {:ok, "bd-1"} = Autopilot.tick(pid)

      Autopilot.tick(pid)
      assert_receive {:escalated, "bd-1", :no_repo_configured, 1}
    end

    # A transient board-read failure must not be mistaken for "Ready is
    # genuinely empty" — `Snapshot.empty/0` has `ready: []` too. If it were,
    # pruning against it would wipe every card's failure entry on a blip,
    # dropping the once-escalated latch and re-paging on the very next
    # failure instead of staying silent.
    test "a board-read blip does not re-arm an already-escalated card" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      snapshot_fun = fn opts ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          1 -> raise "transient board read failure"
          _ -> board("bd-1", opts[:paused])
        end
      end

      pid =
        start(
          paused: false,
          snapshot: snapshot_fun,
          dispatch: fn _ -> {:error, :no_repo_configured} end,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      Autopilot.tick(pid)
      assert_receive {:escalated, "bd-1", :no_repo_configured, 1}

      # tick 2: the board read blows up — the failure entry, and its latch,
      # must survive this untouched.
      assert :idle = Autopilot.tick(pid)
      refute_receive {:escalated, _, _, _}, 50

      # tick 3: same card, same error shape — still latched, so no re-page.
      Autopilot.tick(pid)
      refute_receive {:escalated, _, _, _}, 50
    end

    # Same hazard, the other direction: a retry budget must not be defeated
    # by read blips resetting a non-deterministic error's count back to
    # zero before it reaches the threshold.
    test "a board-read blip does not reset a non-deterministic retry budget" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      snapshot_fun = fn opts ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          n when rem(n, 3) == 1 -> raise "transient board read failure"
          _ -> board("bd-1", opts[:paused])
        end
      end

      pid =
        start(
          paused: false,
          snapshot: snapshot_fun,
          dispatch: fn _ -> {:error, :timeout} end,
          escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end
        )

      for _ <- 1..9, do: Autopilot.tick(pid)

      assert_receive {:escalated, "bd-1", :timeout, _attempts}
    end
  end

  describe "a quota-exhausted pre-flight failure is held, not retried every tick (bd-8lnnnt)" do
    alias Arbiter.Worker.StopReason

    defp quota_reason(retry_after) do
      %StopReason{
        category: :quota_exhausted,
        summary: "5h usage limit reached",
        remediation: nil,
        exit_status: 1,
        signal: nil,
        retry_after: retry_after
      }
    end

    test "does not re-run the probe on the next tick while the reset is still ahead" do
      test = self()
      retry_after = DateTime.add(DateTime.utc_now(), 3600, :second)

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            send(test, {:dispatch_attempt, id})
            {:error, {:auth_check_failed, quota_reason(retry_after)}}
          end
        )

      assert {:error, {:auth_check_failed, _}} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      assert {:held, "bd-1", held_until} = Autopilot.tick(pid)
      assert DateTime.compare(held_until, retry_after) != :lt
      refute_receive {:dispatch_attempt, _}, 50
    end

    test "dispatches again once the known reset time has passed" do
      test = self()
      {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
      retry_after = DateTime.add(DateTime.utc_now(), 3600, :second)

      pid =
        start(
          paused: false,
          now: fn -> Agent.get(clock, & &1) end,
          dispatch: fn id ->
            send(test, {:dispatch_attempt, id})
            {:error, {:auth_check_failed, quota_reason(retry_after)}}
          end
        )

      Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      assert {:held, "bd-1", _} = Autopilot.tick(pid)
      refute_receive {:dispatch_attempt, _}, 50

      Agent.update(clock, fn _ -> DateTime.add(retry_after, 120, :second) end)
      Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
    end

    test "without a known reset time, falls back to a bounded backoff instead of retrying every tick" do
      test = self()
      {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)

      pid =
        start(
          paused: false,
          now: fn -> Agent.get(clock, & &1) end,
          dispatch: fn id ->
            send(test, {:dispatch_attempt, id})
            {:error, {:auth_check_failed, quota_reason(nil)}}
          end
        )

      Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      assert {:held, "bd-1", _} = Autopilot.tick(pid)
      refute_receive {:dispatch_attempt, _}, 50

      Agent.update(clock, fn now -> DateTime.add(now, 3600, :second) end)
      Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
    end

    test "a card that dispatches successfully clears a live hold, so the next failure restarts at count 1" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
      retry_after = DateTime.add(DateTime.utc_now(), 3600, :second)

      dispatch_fun = fn id ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            send(test, {:dispatch_attempt, id})
            {:error, {:auth_check_failed, quota_reason(retry_after)}}

          1 ->
            send(test, {:dispatch_attempt, id})
            {:ok, %{task_id: id}}

          _ ->
            send(test, {:dispatch_attempt, id})
            {:error, {:auth_check_failed, quota_reason(nil)}}
        end
      end

      pid = start(paused: false, now: fn -> Agent.get(clock, & &1) end, dispatch: dispatch_fun)

      Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      # The hold is still live (retry_after is 1h out) — a tick now must not
      # re-attempt.
      assert {:held, "bd-1", _} = Autopilot.tick(pid)
      refute_receive {:dispatch_attempt, _}, 50

      # Advance the clock past the known reset time so the hold expires, and
      # this attempt succeeds — exercising `clear_failure/2` on a hold that
      # was actually live, not one that had already lapsed on its own.
      Agent.update(clock, fn _ -> DateTime.add(retry_after, 120, :second) end)
      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      # A fresh failure right after the success should compute its backoff at
      # count: 1 (the base backoff window), not carry the earlier failure's
      # count forward — proof the success actually cleared the entry rather
      # than just leaving a stale `retry_not_before` behind. The successful
      # dispatch above schedules its own immediate follow-up pass
      # (bd-axgpec), so this fresh failure arrives on its own rather than
      # needing another explicit tick.
      before_next_failure = Agent.get(clock, & &1)
      assert_receive {:dispatch_attempt, "bd-1"}
      await_idle(pid)

      assert {:held, "bd-1", held_until} = Autopilot.tick(pid)
      assert DateTime.compare(held_until, DateTime.add(before_next_failure, 30, :second)) != :gt
    end
  end

  describe "a dispatch does not take the process with it" do
    # The board refreshes *because* a dispatch is happening — Worker.init
    # broadcasts :started mid-flight — so the one moment every open board asks
    # this process a question is the moment a synchronous dispatch would have
    # it blocked. Dispatch is seconds to minutes; the call timeout is five.
    test "the autopilot keeps answering while a promotion is in flight" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            send(test, {:dispatch_started, id, self()})
            assert_receive :release, 2_000
            {:ok, %{task_id: id}}
          end
        )

      spawn_link(fn -> send(test, {:tick_outcome, Autopilot.tick(pid)}) end)
      assert_receive {:dispatch_started, "bd-1", task}

      # Mid-dispatch, and every one of these answers promptly.
      assert Autopilot.paused?(pid, 200) == false
      assert %{paused: false} = Autopilot.board(pid, [], 200)
      assert :ok = Autopilot.pause(pid)
      assert :ok = Autopilot.resume(pid)

      send(task, :release)
      # The tick that started it still gets the outcome, once there is one.
      assert_receive {:tick_outcome, {:ok, "bd-1"}}
    end

    test "a tick that lands mid-dispatch does not start a second one" do
      test = self()

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            send(test, {:dispatch_started, id, self()})
            assert_receive :release, 2_000
            {:ok, %{task_id: id}}
          end
        )

      spawn_link(fn -> send(test, {:tick_outcome, Autopilot.tick(pid)}) end)
      assert_receive {:dispatch_started, "bd-1", task}

      assert {:busy, "bd-1"} = Autopilot.tick(pid, 200)
      refute_receive {:dispatch_started, _, _}, 50

      send(task, :release)
      assert_receive {:tick_outcome, {:ok, "bd-1"}}
    end
  end

  describe "the pause switch" do
    test "starts paused when asked, and dispatches nothing while paused" do
      pid = start(paused: true)

      assert Autopilot.paused?(pid)
      assert :paused = Autopilot.tick(pid)
      refute_receive {:dispatched, _}
    end

    test "resume lets the next tick promote; pause stops it again" do
      pid = start(paused: true)

      assert :ok = Autopilot.resume(pid)
      refute Autopilot.paused?(pid)
      assert {:ok, "bd-1"} = Autopilot.tick(pid)

      assert :ok = Autopilot.pause(pid)
      assert :paused = Autopilot.tick(pid)
    end

    test "the board it hands out carries its own pause state, so reasons match reality" do
      pid = start(paused: true)

      assert %{paused: true} = Autopilot.board(pid)

      Autopilot.resume(pid)
      assert %{paused: false} = Autopilot.board(pid)
    end
  end

  describe "a board read that blows up" do
    test "a failed read promotes nothing rather than crashing the autopilot" do
      pid = start(paused: false, snapshot: fn _ -> raise "no repo" end)

      assert :idle = Autopilot.tick(pid)
      assert Process.alive?(pid)
      refute_receive {:dispatched, _}
    end

    test "the board it hands out is still a board a screen can render" do
      pid = start(paused: false, snapshot: fn _ -> raise "no repo" end)

      board = Autopilot.board(pid)

      # Every column key present and empty, not a stub map: the caller renders
      # four columns off this, and a missing key is a crashed page.
      assert board.ready == []
      assert board.running == []
      assert board.waiting == []
      assert board.closed_today == []
      assert board.promote == nil
      assert board.slots_free == 0
      assert %DateTime{} = board.now
      # It reports itself paused: nothing is draining a queue it cannot read.
      assert board.paused
    end
  end

  describe "announcements" do
    test "a promotion is broadcast so open boards refresh without polling" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      pid = start(paused: false)

      Autopilot.tick(pid)

      assert_receive {:board_dispatched, "bd-1"}
    end

    test "pausing and resuming are broadcast too" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      pid = start(paused: false)

      Autopilot.pause(pid)
      assert_receive {:board_scheduler, :paused}

      Autopilot.resume(pid)
      assert_receive {:board_scheduler, :resumed}
    end
  end

  describe "reactive triggers (bd-axgpec)" do
    # Every test here uses `interval_ms: :never` (the `start/1` default) so
    # any dispatch it sees can only have come from the reactive path, never
    # the fallback tick.

    test "a task closing runs a pass without waiting for the tick" do
      pid = start(paused: false)

      send(pid, {:task_lifecycle, :closed, %{id: "bd-2"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a card promoted to Ready (refined) runs a pass" do
      pid = start(paused: false)

      send(pid, {:task_lifecycle, :updated, %{id: "bd-2"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a worker finishing runs a pass" do
      pid = start(paused: false)

      send(pid, {:event, %{topic: "worker_done", task_id: "bd-9"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a worker failing runs a pass" do
      pid = start(paused: false)

      send(pid, {:event, %{topic: "worker_failed", task_id: "bd-9"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "an unrelated event topic does not run a pass" do
      pid = start(paused: false)

      send(pid, {:event, %{topic: "inbox", task_id: "bd-9"}})

      refute_receive {:dispatched, _}, 100
    end

    # These three drive the trigger through a real `Phoenix.PubSub.broadcast/3`
    # instead of `send/2`, so they actually exercise the `subscribe` calls in
    # `init/1` (and would fail if those were deleted or pointed at the wrong
    # topic). Each uses its own private topic — passed via `:topics` — rather
    # than the real "tasks"/"events" topics, so it isn't exposed to unrelated
    # broadcasts from other async tests in the suite.
    test "a task closing runs a pass when delivered over real PubSub" do
      topic = "autopilot-test-tasks-#{System.unique_integer([:positive])}"
      _pid = start(paused: false, topics: [topic])

      Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:task_lifecycle, :closed, %{id: "bd-2"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a dependency edge add/remove runs a pass when delivered over real PubSub" do
      # `Arbiter.Tasks.Dependencies.broadcast_endpoints/2` reloads each
      # endpoint and re-broadcasts it as `{:task_lifecycle, :updated, issue}`
      # on the "tasks" topic — the same shape used here.
      topic = "autopilot-test-tasks-#{System.unique_integer([:positive])}"
      _pid = start(paused: false, topics: [topic])

      Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:task_lifecycle, :updated, %{id: "bd-2"}})

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a worker finishing runs a pass when delivered over real PubSub" do
      topic = "autopilot-test-events-#{System.unique_integer([:positive])}"
      _pid = start(paused: false, topics: [topic])

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        topic,
        {:event, %{topic: "worker_done", task_id: "bd-9"}}
      )

      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a burst of triggers in quick succession yields exactly one pass" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, dispatched?} = Agent.start_link(fn -> false end)

      pid =
        start(
          paused: false,
          # A dispatched card leaves Ready, same as a real snapshot after a
          # real (synchronous) status transition to :in_progress — otherwise
          # every pass, including a legitimate follow-up, would promote the
          # same card again and this test couldn't tell a coalesced burst
          # from an (incorrect) uncapped redispatch loop.
          snapshot: fn opts ->
            promote = if Agent.get(dispatched?, & &1), do: nil, else: "bd-1"
            board(promote, opts[:paused])
          end,
          dispatch: fn id ->
            Agent.update(dispatched?, fn _ -> true end)
            Agent.update(counter, &(&1 + 1))
            send(test, {:dispatched, id})
            {:ok, %{task_id: id}}
          end
        )

      for _ <- 1..5, do: send(pid, {:task_lifecycle, :updated, %{id: "bd-2"}})

      assert_receive {:dispatched, "bd-1"}, 500
      # Give any (incorrect) extra passes time to land before checking the
      # count — the debounce window is 20ms, so 200ms is generous.
      Process.sleep(200)
      assert Agent.get(counter, & &1) == 1
    end

    test "triggers while paused do not dispatch" do
      pid = start(paused: true)

      send(pid, {:task_lifecycle, :closed, %{id: "bd-2"}})
      send(pid, {:event, %{topic: "worker_done"}})

      refute_receive {:dispatched, _}, 200
    end

    test "a trigger during an in-flight dispatch queues one re-plan for when it completes" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # The first attempt fails (not a success) so the only thing that can
      # cause a second, automatic attempt is the trigger queued while it was
      # in flight — a successful dispatch's own immediate follow-up (tested
      # separately) is deliberately ruled out here.
      dispatch_fun = fn id ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            send(test, {:dispatch_started, id, self()})
            assert_receive :release, 2_000
            send(test, {:dispatched, id})
            {:error, :boom}

          _ ->
            send(test, {:dispatched, id})
            {:ok, %{task_id: id}}
        end
      end

      pid = start(paused: false, dispatch: dispatch_fun)

      spawn_link(fn -> Autopilot.tick(pid, 5_000) end)
      assert_receive {:dispatch_started, "bd-1", task}

      # This trigger lands mid-dispatch, when a fresh pass would just read
      # {:busy, "bd-1"} — it must not be dropped.
      send(pid, {:task_lifecycle, :closed, %{id: "bd-2"}})
      refute_receive {:dispatched, _}, 100

      send(task, :release)

      # The first (failed) attempt completes...
      assert_receive {:dispatched, "bd-1"}, 500
      # ...and the queued re-plan from the trigger above runs once it does,
      # with no further external trigger or explicit tick.
      assert_receive {:dispatched, "bd-1"}, 500
    end

    test "a successful dispatch runs an immediate follow-up pass while cards remain" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      snapshot_fun = fn opts ->
        promote =
          case Agent.get(counter, & &1) do
            0 -> "bd-1"
            1 -> "bd-2"
            _ -> nil
          end

        board(promote, opts[:paused])
      end

      dispatch_fun = fn id ->
        Agent.update(counter, &(&1 + 1))
        send(test, {:dispatched, id})
        {:ok, %{task_id: id}}
      end

      pid = start(paused: false, snapshot: snapshot_fun, dispatch: dispatch_fun)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)

      # No second `tick/2` call: the successful dispatch above should have
      # scheduled its own follow-up pass, which finds "bd-2" still Ready.
      assert_receive {:dispatched, "bd-2"}, 500
    end

    test "a pass that dispatches nothing does not reschedule itself" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      pid =
        start(
          paused: false,
          snapshot: fn _ -> board(nil) end,
          dispatch: fn id ->
            Agent.update(counter, &(&1 + 1))
            send(test, {:dispatched, id})
            {:ok, %{task_id: id}}
          end
        )

      assert :idle = Autopilot.tick(pid)

      refute_receive {:dispatched, _}, 300
      assert Agent.get(counter, & &1) == 0
    end

    test "a failed dispatch with no pending trigger does not reschedule itself" do
      test = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      pid =
        start(
          paused: false,
          dispatch: fn id ->
            Agent.update(counter, &(&1 + 1))
            send(test, {:dispatched, id})
            {:error, :boom}
          end
        )

      assert {:error, :boom} = Autopilot.tick(pid)
      assert_receive {:dispatched, "bd-1"}

      refute_receive {:dispatched, _}, 300
      assert Agent.get(counter, & &1) == 1
    end
  end
end
