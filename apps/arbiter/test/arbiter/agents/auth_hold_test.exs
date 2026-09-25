defmodule Arbiter.Agents.AuthHoldTest do
  # bd-21bmdh: the auth-shaped dispatch hold. Every test runs against a private,
  # unnamed AuthHold paired with a private CredentialWatchdog, so nothing here
  # touches the application singletons other tests read.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.{AuthHold, Claude, Codex, CredentialWatchdog}
  alias Arbiter.Worker.StopReason

  defp start_pair(opts \\ []) do
    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start:
          {CredentialWatchdog, :start_link,
           [[name: nil, enabled: false, adapters: [Claude, Codex]]]}
      })

    {:ok, hold} =
      start_supervised(%{
        id: make_ref(),
        start:
          {AuthHold, :start_link,
           [Keyword.merge([name: nil, credential_watchdog: watchdog], opts)]}
      })

    # The watchdog's recovery signal has to reach *this* hold, not the
    # application singleton.
    :ok = CredentialWatchdog.set_auth_hold(hold, watchdog)

    {hold, watchdog}
  end

  defp auth_reason do
    %StopReason{
      category: :auth_expired,
      summary: "API Error: 401 Invalid authentication credentials",
      remediation: "Re-authenticate",
      exit_status: 1,
      signal: nil
    }
  end

  # Casts are fire-and-forget; a synchronous call to the same process is
  # processed after any cast already in its mailbox.
  defp sync(server), do: _ = :sys.get_state(server)

  describe "opening the hold" do
    test "the first auth death is counted but does not hold" do
      {hold, watchdog} = start_pair()

      assert :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      refute AuthHold.open?(Claude, hold)
      assert %{deaths: 1, open?: false} = AuthHold.status(Claude, hold)
      sync(watchdog)
      refute CredentialWatchdog.expired?(Claude, watchdog)
    end

    test "N consecutive auth deaths (default 2) open the hold and mark the watchdog" do
      {hold, watchdog} = start_pair()

      assert :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      assert :opened = AuthHold.record_death(Claude, auth_reason(), hold)

      assert AuthHold.open?(Claude, hold)
      assert %{deaths: 2, open?: true, opened_at: %DateTime{}} = AuthHold.status(Claude, hold)

      sync(watchdog)
      assert CredentialWatchdog.expired?(Claude, watchdog)
    end

    test "the hold is per provider" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)

      refute AuthHold.open?(Codex, hold)
      assert :counted = AuthHold.record_death(Codex, auth_reason(), hold)
      sync(watchdog)
    end

    test "a further death while open is reported :held and keeps it open" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)

      assert :held = AuthHold.record_death(Claude, auth_reason(), hold)
      assert AuthHold.open?(Claude, hold)
      sync(watchdog)
    end

    test "the threshold is configurable" do
      {hold, watchdog} = start_pair(threshold: 3)

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      refute AuthHold.open?(Claude, hold)
      assert :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      sync(watchdog)
    end

    test "the threshold also reads config :arbiter, :auth_hold" do
      prior = Application.get_env(:arbiter, :auth_hold)
      Application.put_env(:arbiter, :auth_hold, threshold: 1)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :auth_hold, prior),
          else: Application.delete_env(:arbiter, :auth_hold)
      end)

      {hold, watchdog} = start_pair()
      assert :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      sync(watchdog)
    end

    test "a worker that completes on the provider resets the streak (consecutive)" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :ok = AuthHold.record_success(Claude, hold)
      sync(hold)

      assert :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      refute AuthHold.open?(Claude, hold)
      sync(watchdog)
    end

    test "a success does not close an already-open hold (fail-closed)" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      :ok = AuthHold.record_success(Claude, hold)
      sync(hold)

      assert AuthHold.open?(Claude, hold)
      sync(watchdog)
    end
  end

  describe "fail-closed read" do
    test "open?/2 answers true when the hold cannot be read" do
      {:ok, dead} = Agent.start(fn -> nil end)
      Agent.stop(dead)

      assert AuthHold.open?(Claude, dead)
    end

    test "held/2 (the board's display read) answers nil when the hold cannot be read" do
      {:ok, dead} = Agent.start(fn -> nil end)
      Agent.stop(dead)

      assert AuthHold.held(Claude, dead) == nil
    end
  end

  describe "reset paths" do
    test "the watchdog's recovery signal clears the hold" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      sync(watchdog)
      assert CredentialWatchdog.expired?(Claude, watchdog)

      # What `CloudProbe` sends on a passing free check, and what the
      # watchdog's own periodic probe does internally on a passing probe.
      :ok = CredentialWatchdog.mark_recovered(Claude, watchdog)
      sync(watchdog)
      sync(hold)

      refute CredentialWatchdog.expired?(Claude, watchdog)
      refute AuthHold.open?(Claude, hold)
    end

    test "after an automatic recovery the next auth death re-opens at once (probation)" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      :ok = CredentialWatchdog.mark_recovered(Claude, watchdog)
      sync(watchdog)
      sync(hold)
      refute AuthHold.open?(Claude, hold)

      assert :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      sync(watchdog)
    end

    test "a completed worker ends probation" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      :ok = CredentialWatchdog.mark_recovered(Claude, watchdog)
      sync(watchdog)
      sync(hold)
      :ok = AuthHold.record_success(Claude, hold)
      sync(hold)

      assert :counted = AuthHold.record_death(Claude, auth_reason(), hold)
    end

    test "an operator reset clears the hold, the streak and the watchdog mark it set" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      sync(watchdog)

      assert {:ok, [Claude]} = AuthHold.reset(Claude, hold)
      sync(watchdog)
      sync(hold)

      refute AuthHold.open?(Claude, hold)
      refute CredentialWatchdog.expired?(Claude, watchdog)
      # Full reset, not probation: it takes N deaths again.
      assert :counted = AuthHold.record_death(Claude, auth_reason(), hold)
    end

    # bd-3kg53c: a periodic-probe-sourced expiry (or, in production, any expiry
    # `credential_watchdog_adapters: []` leaves with no automatic re-probe) can
    # mark `CredentialWatchdog` without ever opening *this* hold — no worker
    # died on auth, so `entry.open?` is false. Before this fix, `reset/2` only
    # cleared the watchdog when its own hold had been open, so an operator
    # reaching for the one documented lever (`arb breaker reset --auth-hold`)
    # got a silent no-op and the adapter stayed refused until a restart.
    test "an operator reset clears a CredentialWatchdog mark even when this hold was never open" do
      {hold, watchdog} = start_pair()

      refute AuthHold.open?(Claude, hold)

      :ok = CredentialWatchdog.mark_expired(Claude, auth_reason(), watchdog, :periodic_probe)
      sync(watchdog)
      assert CredentialWatchdog.expired?(Claude, watchdog)

      assert {:ok, [Claude]} = AuthHold.reset(Claude, hold)
      sync(watchdog)

      refute CredentialWatchdog.expired?(Claude, watchdog)
    end

    # bd-3kg53c round 2 finding 2: `mark_recovered/3`'s default source
    # (`:worker_report`) does not recover a `:usage_poll`-raised mark
    # (`recovers?(:usage_poll, :worker_report)` is false by design — an
    # unrelated CLI probe passing says nothing about the usage poll's own
    # cached credential). Before this fix, `AuthHold.reset/2` went through
    # `mark_recovered/3`, so `arb breaker reset --auth-hold <provider>`
    # silently no-opped on a usage-poll-only mark. An explicit operator reset
    # must be an unconditional override, not another recovery signal.
    test "an operator reset clears a CredentialWatchdog mark raised by :usage_poll" do
      {hold, watchdog} = start_pair()

      # :usage_poll never closes the dispatch gate on its own (bd-6jjgk0
      # finding 1), so `expired?/2` stays false — `escalated?/2` is the
      # source-agnostic check for "is there still an outstanding mark".
      :ok = CredentialWatchdog.mark_expired(Claude, auth_reason(), watchdog, :usage_poll)
      sync(watchdog)
      assert CredentialWatchdog.escalated?(Claude, watchdog)

      assert {:ok, [Claude]} = AuthHold.reset(Claude, hold)
      sync(watchdog)

      refute CredentialWatchdog.escalated?(Claude, watchdog)
    end

    test "reset(:all) clears every open hold" do
      {hold, watchdog} = start_pair(threshold: 1)

      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Codex, auth_reason(), hold)

      assert {:ok, cleared} = AuthHold.reset(:all, hold)
      assert Enum.sort(cleared) == Enum.sort([Claude, Codex])
      refute AuthHold.open?(Claude, hold)
      refute AuthHold.open?(Codex, hold)
      sync(watchdog)
    end

    test "list/1 reports open holds and live streaks" do
      {hold, watchdog} = start_pair()

      :counted = AuthHold.record_death(Codex, auth_reason(), hold)
      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)

      by_adapter = Map.new(AuthHold.list(hold), &{&1.adapter, &1})
      assert %{open?: true, deaths: 2, threshold: 2} = by_adapter[Claude]
      assert %{open?: false, deaths: 1} = by_adapter[Codex]
      sync(watchdog)
    end
  end
end
