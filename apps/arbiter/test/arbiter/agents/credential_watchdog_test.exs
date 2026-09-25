# Probe-safe stand-in adapters: neither exports `auth_probe_argv/1`, so
# `Arbiter.Agents.Preflight.check/2` returns `:skipped` (treated as a healthy
# probe) without ever spawning a real agent CLI. Used by the runtime-config
# tests below, which need a Watchdog that actually polls.
defmodule Arbiter.Agents.CredentialWatchdogTest.FakeAdapterA do
  @moduledoc false
end

defmodule Arbiter.Agents.CredentialWatchdogTest.FakeAdapterB do
  @moduledoc false
end

# bd-svczq4: a probe that always outruns the watchdog. `Arbiter.Agents.Preflight`
# answers a timeout with `{:warn, reason}` — advisory, never evidence about the
# credentials — and this adapter is how the Watchdog's handling of that verdict
# is driven deterministically, without a real CLI.
defmodule Arbiter.Agents.CredentialWatchdogTest.SlowProbeAdapter do
  @moduledoc false
  def provider, do: "slowprobe"
  def spawn_env(_opts \\ []), do: []
  def auth_probe_argv(_opts \\ []), do: {:ok, ["sh", "-c", "sleep 30"]}
end

defmodule Arbiter.Agents.CredentialWatchdogTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.CredentialWatchdogTest.FakeAdapterA
  alias Arbiter.Agents.CredentialWatchdogTest.FakeAdapterB
  alias Arbiter.Agents.CredentialWatchdogTest.SlowProbeAdapter
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker.StopReason

  # Start an isolated, unnamed Watchdog for each test so it does not conflict with
  # the application-started singleton (which is enabled: false in test config but
  # still occupies the __MODULE__ name). We pass the returned pid explicitly to
  # all API calls that accept a server argument.
  defp start_watchdog(opts \\ []) do
    defaults = [
      name: nil,
      enabled: false,
      interval_ms: 100,
      recovery_interval_ms: 50,
      adapters: [Arbiter.Agents.Claude, Arbiter.Agents.Gemini]
    ]

    merged = Keyword.merge(defaults, opts)
    # start_link uses name: nil → starts unnamed; we hold the pid directly.
    {:ok, pid} =
      start_supervised(%{
        id: make_ref(),
        start: {CredentialWatchdog, :start_link, [merged]}
      })

    pid
  end

  defp auth_expired_reason do
    %StopReason{
      category: :auth_expired,
      summary: "401 invalid authentication credentials",
      remediation: "Re-authenticate the agent CLI, then re-dispatch.",
      exit_status: 1,
      signal: nil
    }
  end

  describe "expired?/2" do
    test "returns false before any expiry is recorded" do
      pid = start_watchdog()
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, pid)
    end

    test "returns false for an unknown adapter" do
      pid = start_watchdog()
      refute CredentialWatchdog.expired?(SomeRandomAdapter, pid)
    end

    test "returns false when the watchdog is not running" do
      # No watchdog started — expired?/1 must not crash the caller.
      # This calls the module-name default, which exists (app-started, enabled: false)
      # and knows no adapters as expired.
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude)
    end
  end

  describe "mark_expired/3" do
    test "marks the adapter as expired so expired?/2 returns true" do
      pid = start_watchdog()
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)

      # Give the cast time to be processed.
      Process.sleep(20)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Gemini, pid)
    end

    test "does not re-escalate when the adapter is already known-expired" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-dedup-ws", prefix: "cwd"})
      pid = start_watchdog()

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)

      count_before =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      # A second mark_expired must not send a duplicate escalation.
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)

      count_after =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      assert count_after == count_before
    end

    test "restates the outstanding escalation's body when mark_expired/4 repeats with a growing counter (bd-6jjgk0 r4f1)" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-restate-ws", prefix: "cwre"})
      pid = start_watchdog()

      first_reason = %{auth_expired_reason() | summary: "2 consecutive 401s from the usage poll"}
      second_reason = %{auth_expired_reason() | summary: "7 consecutive 401s from the usage poll"}

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, first_reason, pid, :usage_poll)
      :sys.get_state(pid)

      :ok =
        CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, second_reason, pid, :usage_poll)

      :sys.get_state(pid)

      # Still exactly one row (no duplicate insert)...
      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "credentials expired"))

      # ...but its body now shows the latest count, not the one from the first
      # cast that opened the episode (finding 1, round 2: `already_expired?`
      # used to drop every repeat cast silently, freezing the body forever).
      assert escalation.body =~ "7 consecutive 401s"
      refute escalation.body =~ "2 consecutive 401s"
    end

    test "escalates to the coordinator across all active workspaces" do
      {:ok, ws1} = Ash.create(Workspace, %{name: "cw-ws1", prefix: "cw1"})
      {:ok, ws2} = Ash.create(Workspace, %{name: "cw-ws2", prefix: "cw2"})
      pid = start_watchdog()

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(100)

      esc1 =
        Message.inbox("admiral", workspace_id: ws1.id)
        |> Enum.find(&(&1.kind == :escalation))

      esc2 =
        Message.inbox("admiral", workspace_id: ws2.id)
        |> Enum.find(&(&1.kind == :escalation))

      assert esc1, "expected escalation in ws1 inbox"
      assert esc2, "expected escalation in ws2 inbox"

      assert esc1.subject =~ "credentials expired"
      assert esc1.body =~ "Proactive credential probe"
      assert esc1.body =~ "Re-authenticate"
    end
  end

  describe "mark_recovered/2 clears the outstanding escalation (bd-6jjgk0)" do
    test "recovering after mark_expired/3 clears the escalation and posts a restored notice" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-recover-ws", prefix: "cwr"})
      pid = start_watchdog()

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "credentials expired"))

      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid)
      :sys.get_state(pid)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      cleared = Ash.get!(Message, escalation.id)
      assert cleared.cleared_at

      assert [restored] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "restored"))

      assert restored.body =~ "Claude"
    end

    test "a later mark_expired/3 after recovery opens a fresh episode" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-reopen-ws", prefix: "cwo"})
      pid = start_watchdog()

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)
      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid)
      :sys.get_state(pid)
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      assert [_second] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "credentials expired"))
    end
  end

  # bd-6jjgk0: the reported flap — CloudProbe's `/api/oauth/usage` poll marks
  # an adapter expired (`:usage_poll`), the Watchdog's own periodic CLI probe
  # then passes on a completely separate, still-valid credential, and used to
  # clear the escalation and post "restored" anyway — only for the next
  # usage-poll cycle to open a fresh one. That turned one outage into a
  # "restored"/"expired" pair every ~5 minutes.
  describe "source-scoped recovery: a recovering signal only clears its own source (bd-6jjgk0)" do
    test "a passing periodic CLI probe reopens the dispatch gate without clearing a :usage_poll-raised escalation" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-flap-ws", prefix: "cwf"})

      # FakeAdapterA exports no auth_probe_argv/1, so Preflight.check/2 answers
      # :skipped — treated as a healthy probe without spawning a real CLI.
      pid =
        start_watchdog(
          adapters: [FakeAdapterA],
          enabled: true,
          interval_ms: 60_000,
          recovery_interval_ms: 60_000
        )

      :ok = CredentialWatchdog.mark_expired(FakeAdapterA, auth_expired_reason(), pid, :usage_poll)
      :sys.get_state(pid)

      assert [_escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "credentials expired"))

      # `:usage_poll` reads a credential the worker CLI never touches (#1875),
      # so it must never close the dispatch gate on its own (bd-6jjgk0
      # finding 1) — only assert it here to prove the *escalation*, not the
      # gate, is what raised.
      refute CredentialWatchdog.expired?(FakeAdapterA, pid),
             "a :usage_poll-raised expiry must never close the dispatch gate by itself"

      send(pid, :check)
      _ = :sys.get_state(pid)

      refute CredentialWatchdog.expired?(FakeAdapterA, pid),
             "a :periodic_probe success reopens the dispatch gate regardless of what raised " <>
               "the outstanding escalation — workers read a different, healthy credential"

      assert Message.inbox("admiral", workspace_id: ws.id)
             |> Enum.filter(&(&1.subject =~ "restored")) == [],
             "no spurious \"restored\" message for a source that never recovered"

      # The original escalation is still the single outstanding row — no
      # duplicate/second "expired" message was raised either.
      assert [_still_one] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "credentials expired"))
    end

    test "recovering via the same source that raised the expiry clears it" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-flap-match-ws", prefix: "cwm"})
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      :sys.get_state(pid)
      # A :usage_poll expiry never closes the dispatch gate on its own
      # (bd-6jjgk0 finding 1) — assert the escalation, not the gate, here.
      assert CredentialWatchdog.escalated?(Arbiter.Agents.Claude, pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid, :usage_poll)
      :sys.get_state(pid)

      refute CredentialWatchdog.escalated?(Arbiter.Agents.Claude, pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      assert [restored] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "restored"))

      # bd-6jjgk0 finding 3: the subject itself must name the usage-poll
      # signal, not read as a full "Claude credentials restored" — a
      # gate-source episode for the same adapter could still be outstanding.
      assert restored.subject =~ "usage-poll signal"
    end

    test "a mismatched mark_recovered/3 source clears the dispatch gate but leaves the escalation open" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-flap-mismatch-ws", prefix: "cwx"})
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      :sys.get_state(pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      # Default source is :worker_report — mismatched against :usage_poll, so
      # the escalation (raised by :usage_poll) stays open. :worker_report is
      # still a gate source, so if the gate had been closed by some other
      # gate-source expiry it would reopen here — it is already open in this
      # scenario since :usage_poll never closed it (bd-6jjgk0 finding 1).
      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid)
      :sys.get_state(pid)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      assert Message.inbox("admiral", workspace_id: ws.id)
             |> Enum.filter(&(&1.subject =~ "restored")) == []
    end
  end

  # bd-6jjgk0 round 3, finding 1: a real outage where the worker credential is
  # actually dead must still close the dispatch gate even while an unrelated
  # `:usage_poll` episode (a separately cached token, #1875) is outstanding for
  # the same adapter. Before this fix, `already_expired?/2` read one shared
  # per-adapter status, so once a `:usage_poll` expiry was recorded, a later
  # gate-source (`:periodic_probe`/`:worker_report`) expiry for the same
  # adapter was silently dropped — the gate stayed open and the mailbox never
  # got the "dispatches suspended" escalation, while `Dispatch` kept sending
  # workers into a dead credential.
  describe "per-source episodes: gate-source expiry not masked by :usage_poll (bd-6jjgk0 r3f1)" do
    test "a gate-source mark_expired/4 still closes the gate while a :usage_poll episode is open" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-r3f1-ws", prefix: "cwg"})
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      :sys.get_state(pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid),
             "a gate-source expiry must close the gate even while a :usage_poll episode " <>
               "is outstanding for the same adapter"

      subjects = Message.inbox("admiral", workspace_id: ws.id) |> Enum.map(& &1.subject)
      assert Enum.count(subjects, &(&1 =~ "credentials expired — proactive detection")) == 1
      assert Enum.count(subjects, &(&1 =~ "credentials expired — usage-poll signal")) == 1
    end

    test "a periodic-probe expiry still closes the gate while a :usage_poll episode is open" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-r3f1b-ws", prefix: "cwh"})
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      :sys.get_state(pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      # Same dedupe path a real periodic CLI-probe :auth_expired result takes
      # (`probe_one/2`'s already_expired?/3 check) — driven directly since
      # Claude has no real CLI to probe in CI.
      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :periodic_probe
        )

      :sys.get_state(pid)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      assert [_] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "usage-poll signal"))

      assert [_] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "proactive detection"))
    end
  end

  # bd-6jjgk0 round 3, finding 2: a `:usage_poll` success must only clear a
  # `:usage_poll`-raised episode. Before this fix, `recovers?/2` had a
  # catch-all `true` clause, so a `:usage_poll` success also cleared (and
  # posted "restored" for) an outstanding `:periodic_probe`/`:worker_report`
  # episode while the gate — which only those sources control — stayed
  # closed, reintroducing the expired/restored flap this task exists to fix.
  describe "a :usage_poll recovery never clears a gate-source episode (bd-6jjgk0 r3f2)" do
    test "a :usage_poll recovery leaves an outstanding gate-source episode open and the gate closed" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-r3f2-ws", prefix: "cwr3"})
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      :sys.get_state(pid)

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      :sys.get_state(pid)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid, :usage_poll)
      :sys.get_state(pid)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid),
             "a :usage_poll recovery must not reopen a gate that a gate-source expiry closed"

      # The :usage_poll episode is cleared and restored...
      assert [_restored] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "restored"))

      # ...but the gate-source (:worker_report) episode is untouched: still
      # outstanding (unread, uncleared), with no "restored" message of its own.
      assert [still_open] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.subject =~ "proactive detection"))

      refute still_open.cleared_at
    end
  end

  describe "periodic probe (handle_info :check)" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-probe-ws", prefix: "cwp"})
      {:ok, ws: ws}
    end

    test "marks expired and escalates when probe returns :auth_expired", %{ws: ws} do
      pid = start_watchdog(adapters: [Arbiter.Agents.Claude])

      # Drive mark_expired directly (Preflight.check on Claude in CI has no CLI,
      # so we avoid a real probe and test the state + escalation path instead).
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(100)

      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation))

      assert escalation
      assert escalation.subject =~ "Claude"
      assert escalation.subject =~ "credentials expired"
    end

    test "reset/1 clears all expiry state", %{ws: _ws} do
      pid = start_watchdog(adapters: [Arbiter.Agents.Claude])

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(20)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.reset(pid)
      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)
    end
  end

  # ---- a probe timeout is advisory, never a credential verdict (bd-svczq4) --

  describe "probe timeout ({:warn, reason})" do
    setup do
      previous = Application.get_env(:arbiter, Arbiter.Agents.Preflight)
      Application.put_env(:arbiter, Arbiter.Agents.Preflight, timeout_ms: 150)

      on_exit(fn ->
        if previous do
          Application.put_env(:arbiter, Arbiter.Agents.Preflight, previous)
        else
          Application.delete_env(:arbiter, Arbiter.Agents.Preflight)
        end
      end)

      :ok
    end

    # Enabled (a disabled Watchdog's `:check` is a no-op), but with intervals
    # long enough that only the explicit `send(pid, :check)` below ever ticks it.
    defp start_watchdog_live(adapters) do
      start_watchdog(
        adapters: adapters,
        enabled: true,
        interval_ms: 60_000,
        recovery_interval_ms: 60_000
      )
    end

    test "a slow probe does not mark the adapter expired" do
      pid = start_watchdog_live([SlowProbeAdapter])

      send(pid, :check)
      _ = :sys.get_state(pid)

      refute CredentialWatchdog.expired?(SlowProbeAdapter, pid)
    end

    test "a slow probe does not recover an adapter a worker just flagged" do
      pid = start_watchdog_live([SlowProbeAdapter])

      :ok = CredentialWatchdog.mark_expired(SlowProbeAdapter, auth_expired_reason(), pid)
      assert_eventually(fn -> CredentialWatchdog.expired?(SlowProbeAdapter, pid) end)

      # The probe times out rather than answering. That says nothing about the
      # credentials, so the mark must survive it — a `{:warn, _}` treated as a
      # healthy probe would silently clear a real expiry.
      send(pid, :check)
      _ = :sys.get_state(pid)

      assert CredentialWatchdog.expired?(SlowProbeAdapter, pid)
    end
  end

  # ---- empty adapter list is a supported no-probe posture (bd-2jgs2h) ------

  describe "empty adapter list (:adapters set to [])" do
    test "expired?/2, mark_expired/3 and mark_recovered/2 all still work with nothing probed" do
      pid = start_watchdog(adapters: [], enabled: true, interval_ms: 50, recovery_interval_ms: 50)

      refute CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      assert_eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid) end)

      # A live periodic tick over an empty adapter list must not clear (or
      # otherwise disturb) a mark set out-of-band — nothing is probing it.
      # Drive the tick directly instead of waiting on the timer, and use
      # `:sys.get_state/1` as a deterministic barrier: it only replies once
      # the `:check` message ahead of it in the mailbox has been handled.
      send(pid, :check)
      _ = :sys.get_state(pid)
      assert CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Claude, pid)
      assert_eventually(fn -> not CredentialWatchdog.expired?(Arbiter.Agents.Claude, pid) end)
    end
  end

  # ---- operator inspection (bd-3kg53c) -------------------------------------
  #
  # `expired?/2` answers "is dispatch refused for this one adapter", but an
  # operator staring at a refusal needs "what does the Watchdog know, across
  # every adapter" without guessing which one to ask about first — the whole
  # point of a lever that beats "restart the server".

  describe "list/2" do
    test "empty when nothing is expired" do
      pid = start_watchdog()
      assert CredentialWatchdog.list(pid) == []
    end

    test "reports a gate-closing (dispatch-refusing) expiry" do
      pid = start_watchdog()
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Gemini, auth_expired_reason(), pid)
      assert_eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Gemini, pid) end)

      assert [entry] = CredentialWatchdog.list(pid)
      assert entry.adapter == Arbiter.Agents.Gemini
      assert entry.provider == "gemini"
      assert entry.gated? == true
      assert [%{source: :worker_report, summary: summary}] = entry.sources
      assert summary =~ "auth"
    end

    test "reports a usage-poll-only expiry as escalated but not gate-closing" do
      pid = start_watchdog()

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Claude,
          auth_expired_reason(),
          pid,
          :usage_poll
        )

      assert_eventually(fn -> CredentialWatchdog.escalated?(Arbiter.Agents.Claude, pid) end)

      assert [entry] = CredentialWatchdog.list(pid)
      assert entry.gated? == false
      assert [%{source: :usage_poll}] = entry.sources
    end

    test "drops an adapter once every one of its sources recovers" do
      pid = start_watchdog()
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Codex, auth_expired_reason(), pid)
      assert_eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Codex, pid) end)

      :ok = CredentialWatchdog.mark_recovered(Arbiter.Agents.Codex, pid)
      assert_eventually(fn -> not CredentialWatchdog.expired?(Arbiter.Agents.Codex, pid) end)

      assert CredentialWatchdog.list(pid) == []
    end
  end

  # ---- runtime configuration (bd-ajgve2) -----------------------------------

  describe "probe_adapters/1" do
    setup :reset_watchdog_settings

    test "defaults to every adapter in Arbiter.Agents.adapters/0 when nothing is set" do
      assert Enum.sort(CredentialWatchdog.probe_adapters()) ==
               Enum.sort(Map.values(Arbiter.Agents.adapters()))
    end

    test "honors an Arbiter.Settings override, resolving names to adapter modules" do
      {:ok, _} = Settings.set_credential_watchdog_adapters(["claude", "gemini"])

      assert CredentialWatchdog.probe_adapters() == [
               Arbiter.Agents.Claude,
               Arbiter.Agents.Gemini
             ]

      refute Arbiter.Agents.Codex in CredentialWatchdog.probe_adapters()
    end

    test "an empty Settings list means probe nothing" do
      {:ok, []} = Settings.set_credential_watchdog_adapters([])
      assert CredentialWatchdog.probe_adapters() == []
    end

    test "explicit start_link opts still win over Settings" do
      {:ok, _} = Settings.set_credential_watchdog_adapters(["claude"])
      assert CredentialWatchdog.probe_adapters(adapters: [FakeAdapterA]) == [FakeAdapterA]
    end
  end

  describe "poll_interval_ms/1 + recovery_interval_ms/1" do
    setup :reset_watchdog_settings

    test "fall back to the hardcoded defaults when nothing is set" do
      assert CredentialWatchdog.poll_interval_ms() == 300_000
      assert CredentialWatchdog.recovery_interval_ms() == 60_000
    end

    test "read Arbiter.Settings when set" do
      {:ok, _} = Settings.set_credential_watchdog_interval_ms(900_000)
      {:ok, _} = Settings.set_credential_watchdog_recovery_interval_ms(120_000)

      assert CredentialWatchdog.poll_interval_ms() == 900_000
      assert CredentialWatchdog.recovery_interval_ms() == 120_000
    end

    test "explicit opts still win over Settings" do
      {:ok, _} = Settings.set_credential_watchdog_interval_ms(900_000)
      assert CredentialWatchdog.poll_interval_ms(interval_ms: 42) == 42
    end
  end

  describe "live config re-read on each poll cycle" do
    setup :reset_watchdog_settings

    setup do
      {:ok, _ws} = Ash.create(Workspace, %{name: "cw-live-ws", prefix: "cwl"})
      put_watchdog_env(adapters: [FakeAdapterA], interval_ms: 50, recovery_interval_ms: 50)
      :ok
    end

    test "dropping an adapter via Arbiter.Settings stops probing it, with no restart" do
      pid = start_polling_watchdog()

      # Baseline: FakeAdapterA is in the probe list, so a poll clears its expiry
      # (Preflight returns :skipped for an adapter with no probe argv).
      expire(FakeAdapterA, pid)
      assert_eventually(fn -> not CredentialWatchdog.expired?(FakeAdapterA, pid) end)

      # Drop it at runtime. The running server must pick this up on its next tick.
      {:ok, []} = Settings.set_credential_watchdog_adapters([])
      expire(FakeAdapterA, pid)
      Process.sleep(300)

      assert CredentialWatchdog.expired?(FakeAdapterA, pid),
             "expected FakeAdapterA to stop being probed once Settings excluded it"

      # Clearing the override falls back to the app-env list, again with no restart.
      {:ok, nil} = Settings.set_credential_watchdog_adapters(nil)
      assert_eventually(fn -> not CredentialWatchdog.expired?(FakeAdapterA, pid) end)
    end

    test "adding an adapter via app env starts probing it, with no restart" do
      pid = start_polling_watchdog()

      expire(FakeAdapterA, pid)
      expire(FakeAdapterB, pid)

      assert_eventually(fn -> not CredentialWatchdog.expired?(FakeAdapterA, pid) end)

      assert CredentialWatchdog.expired?(FakeAdapterB, pid),
             "FakeAdapterB is not in the probe list, so nothing should have cleared it"

      put_watchdog_env(
        adapters: [FakeAdapterA, FakeAdapterB],
        interval_ms: 50,
        recovery_interval_ms: 50
      )

      assert_eventually(fn -> not CredentialWatchdog.expired?(FakeAdapterB, pid) end)
    end

    test "an interval change via Arbiter.Settings takes effect without a restart" do
      pid = start_polling_watchdog()

      expire(FakeAdapterA, pid)
      assert_eventually(fn -> not CredentialWatchdog.expired?(FakeAdapterA, pid) end)

      {:ok, _} = Settings.set_credential_watchdog_interval_ms(30_000)
      {:ok, _} = Settings.set_credential_watchdog_recovery_interval_ms(30_000)

      # Let the currently-armed 50ms timer fire; it re-arms at the new interval.
      Process.sleep(200)

      expire(FakeAdapterA, pid)
      Process.sleep(400)

      assert CredentialWatchdog.expired?(FakeAdapterA, pid),
             "expected the next poll to be 30s out, so nothing should have cleared the expiry"
    end

    test "the expiry state machine still tracks adapters outside the probe list" do
      pid = start_polling_watchdog()

      expire(FakeAdapterB, pid)
      Process.sleep(200)

      # Not probed, so it stays expired — and reset/1 still clears it.
      assert CredentialWatchdog.expired?(FakeAdapterB, pid)
      :ok = CredentialWatchdog.reset(pid)
      refute CredentialWatchdog.expired?(FakeAdapterB, pid)
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp reset_watchdog_settings(_ctx) do
    on_exit(fn ->
      Settings.set_credential_watchdog_adapters(nil)
      Settings.set_credential_watchdog_interval_ms(nil)
      Settings.set_credential_watchdog_recovery_interval_ms(nil)
    end)

    :ok
  end

  defp put_watchdog_env(kw) do
    previous = Application.get_env(:arbiter, :credential_watchdog)
    Application.put_env(:arbiter, :credential_watchdog, kw)

    on_exit(fn ->
      if previous do
        Application.put_env(:arbiter, :credential_watchdog, previous)
      else
        Application.delete_env(:arbiter, :credential_watchdog)
      end
    end)
  end

  # An unnamed Watchdog that actually polls, taking its adapter list and
  # intervals from app env / Settings rather than frozen start_link opts.
  defp start_polling_watchdog do
    {:ok, pid} =
      start_supervised(%{
        id: make_ref(),
        start: {CredentialWatchdog, :start_link, [[name: nil, enabled: true]]}
      })

    pid
  end

  defp expire(adapter, pid) do
    :ok = CredentialWatchdog.mark_expired(adapter, auth_expired_reason(), pid)
    assert_eventually(fn -> CredentialWatchdog.expired?(adapter, pid) end)
  end

  defp assert_eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true within the timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
