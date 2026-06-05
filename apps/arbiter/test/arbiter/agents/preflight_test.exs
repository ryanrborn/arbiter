defmodule Arbiter.Agents.PreflightTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Preflight

  describe "check/2 with a probe_command override" do
    test "a clean ping authenticates → :ok" do
      assert :ok =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "echo pong; exit 0"],
                 probe_env: []
               )
    end

    test "a 401 probe → {:error, :auth_expired} with re-auth remediation" do
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   "echo 'API Error: 401 Invalid authentication credentials'; exit 1"
                 ],
                 probe_env: []
               )

      assert reason.category == :auth_expired
      assert reason.remediation =~ "Re-authenticate"
    end

    test "a clean exit that still printed an auth error is refused" do
      # Some CLIs print the error but exit 0; the output classifier must catch it.
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "echo 'invalid authentication credentials'; exit 0"],
                 probe_env: []
               )

      assert reason.category == :auth_expired
    end

    test "a missing executable is refused (not a silent pass)" do
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["/no/such/cli/here", "--print", "ping"],
                 probe_env: []
               )

      assert reason.category == :crashed
      assert reason.summary =~ "not found"
    end

    test "a hung probe is refused via the timeout path" do
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 5"],
                 probe_env: [],
                 timeout_ms: 80
               )

      assert reason.category == :stalled
    end
  end

  describe "check/2 with an unprobeable adapter" do
    defmodule NoProbeAdapter do
      # An adapter that doesn't implement auth_probe_argv/1.
      def provider, do: "noprobe"
    end

    test "returns :skipped — never blocks on an absent probe" do
      assert :skipped = Preflight.check(NoProbeAdapter, [])
    end
  end
end
