defmodule Arbiter.Agents.PreflightTest do
  # async: false — the CLAUDE_CODE_OAUTH_TOKEN fallback tests below mutate the
  # process-global OS environment (bd-2zigo1).
  use ExUnit.Case, async: false

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

  describe "check/2 CLAUDE_CODE_OAUTH_TOKEN fallback (bd-2zigo1)" do
    setup do
      prev_oauth_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        Claude.Config.clear()

        case prev_oauth_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "Claude.spawn_env/1 exports the token verbatim, never remapped" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

      assert {"CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token"} in Claude.spawn_env([])
    end

    test "probe succeeds via the install-wide CLAUDE_CODE_OAUTH_TOKEN even with no personal API key/session" do
      # Simulates the incident: the operator's personal ~/.claude/.credentials.json
      # OAuth session is expired/absent (no api_key configured either), but the
      # install-wide CLAUDE_CODE_OAUTH_TOKEN is set.
      #
      # NOTE: this test alone does NOT prove the probe env comes from
      # `spawn_env/1` — Erlang's `Port.open` `{:env, ...}` option *extends*
      # (rather than replaces) the BEAM's own OS environment, so a var set via
      # `System.put_env/2` reaches the spawned `sh` regardless of what
      # `spawn_env/1` returns. That wiring is verified separately below with
      # `SpawnEnvAdapter`, which uses a sentinel var never set on the BEAM
      # itself. This test instead pins the end-to-end incident scenario: with
      # `CLAUDE_CODE_OAUTH_TOKEN` present, the real `Claude` adapter's probe
      # authenticates.
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

      assert :ok =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   ~s(if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then echo pong; exit 0; else echo '401 invalid authentication credentials'; exit 1; fi)
                 ]
               )
    end

    test "probe fails without CLAUDE_CODE_OAUTH_TOKEN or an api_key (control case)" do
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   ~s(if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then echo pong; exit 0; else echo '401 invalid authentication credentials'; exit 1; fi)
                 ]
               )

      assert reason.category == :auth_expired
    end
  end

  describe "check/2 probe env sourcing (bd-2zigo1)" do
    defmodule SpawnEnvAdapter do
      @moduledoc false
      def spawn_env(_opts), do: [{"ARB_PROBE_SENTINEL", "from-spawn-env"}]
    end

    test "the probe env comes from the adapter's spawn_env/1, not the BEAM's inherited env" do
      # ARB_PROBE_SENTINEL is never set on the BEAM process itself, so the
      # only way the spawned `sh` can see it is if `Preflight.check/2` actually
      # calls `SpawnEnvAdapter.spawn_env/1` and threads its output into the
      # port's env (`safe_spawn_env/2`, preflight.ex:89) — unlike the
      # `System.put_env/2` scenario above, there's no ambient inheritance to
      # produce a false pass here.
      refute System.get_env("ARB_PROBE_SENTINEL")

      assert :ok =
               Preflight.check(SpawnEnvAdapter,
                 probe_command: ["sh", "-c", ~s(test "$ARB_PROBE_SENTINEL" = from-spawn-env)]
               )
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
