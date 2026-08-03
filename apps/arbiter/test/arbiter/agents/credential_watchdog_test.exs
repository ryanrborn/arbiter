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

defmodule Arbiter.Agents.CredentialWatchdogTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.CredentialWatchdogTest.FakeAdapterA
  alias Arbiter.Agents.CredentialWatchdogTest.FakeAdapterB
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
      Process.sleep(20)

      count_before =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      # A second mark_expired must not send a duplicate escalation.
      :ok = CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(20)

      count_after =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      assert count_after == count_before
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
