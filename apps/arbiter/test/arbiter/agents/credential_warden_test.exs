defmodule Arbiter.Agents.CredentialWardenTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.CredentialWarden
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat.StopReason

  # Start an isolated, unnamed Warden for each test so it does not conflict with
  # the application-started singleton (which is enabled: false in test config but
  # still occupies the __MODULE__ name). We pass the returned pid explicitly to
  # all API calls that accept a server argument.
  defp start_warden(opts \\ []) do
    defaults = [
      name: nil,
      enabled: false,
      interval_ms: 100,
      recovery_interval_ms: 50,
      adapters: [Arbiter.Agents.Claude, Arbiter.Agents.Gemini]
    ]

    merged = Keyword.merge(defaults, opts)
    # start_link uses name: nil → starts unnamed; we hold the pid directly.
    {:ok, pid} = start_supervised(%{
      id: make_ref(),
      start: {CredentialWarden, :start_link, [merged]}
    })
    pid
  end

  defp auth_expired_reason do
    %StopReason{
      category: :auth_expired,
      summary: "401 invalid authentication credentials",
      remediation: "Re-authenticate the agent CLI, then re-sling.",
      exit_status: 1,
      signal: nil
    }
  end

  describe "expired?/2" do
    test "returns false before any expiry is recorded" do
      pid = start_warden()
      refute CredentialWarden.expired?(Arbiter.Agents.Claude, pid)
      refute CredentialWarden.expired?(Arbiter.Agents.Gemini, pid)
    end

    test "returns false for an unknown adapter" do
      pid = start_warden()
      refute CredentialWarden.expired?(SomeRandomAdapter, pid)
    end

    test "returns false when the warden is not running" do
      # No warden started — expired?/1 must not crash the caller.
      # This calls the module-name default, which exists (app-started, enabled: false)
      # and knows no adapters as expired.
      refute CredentialWarden.expired?(Arbiter.Agents.Claude)
    end
  end

  describe "mark_expired/3" do
    test "marks the adapter as expired so expired?/2 returns true" do
      pid = start_warden()
      refute CredentialWarden.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)

      # Give the cast time to be processed.
      Process.sleep(20)

      assert CredentialWarden.expired?(Arbiter.Agents.Claude, pid)
      refute CredentialWarden.expired?(Arbiter.Agents.Gemini, pid)
    end

    test "does not re-escalate when the adapter is already known-expired" do
      {:ok, ws} = Ash.create(Workspace, %{name: "cw-dedup-ws", prefix: "cwd"})
      pid = start_warden()

      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(20)

      count_before =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      # A second mark_expired must not send a duplicate escalation.
      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(20)

      count_after =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.count(&(&1.kind == :escalation))

      assert count_after == count_before
    end

    test "escalates to Admiral across all active workspaces" do
      {:ok, ws1} = Ash.create(Workspace, %{name: "cw-ws1", prefix: "cw1"})
      {:ok, ws2} = Ash.create(Workspace, %{name: "cw-ws2", prefix: "cw2"})
      pid = start_warden()

      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
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
      pid = start_warden(adapters: [Arbiter.Agents.Claude])

      # Drive mark_expired directly (Preflight.check on Claude in CI has no CLI,
      # so we avoid a real probe and test the state + escalation path instead).
      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(100)

      assert CredentialWarden.expired?(Arbiter.Agents.Claude, pid)

      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation))

      assert escalation
      assert escalation.subject =~ "Claude"
      assert escalation.subject =~ "credentials expired"
    end

    test "reset/1 clears all expiry state", %{ws: _ws} do
      pid = start_warden(adapters: [Arbiter.Agents.Claude])

      :ok = CredentialWarden.mark_expired(Arbiter.Agents.Claude, auth_expired_reason(), pid)
      Process.sleep(20)
      assert CredentialWarden.expired?(Arbiter.Agents.Claude, pid)

      :ok = CredentialWarden.reset(pid)
      refute CredentialWarden.expired?(Arbiter.Agents.Claude, pid)
    end
  end
end
