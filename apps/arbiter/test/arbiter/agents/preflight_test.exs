defmodule Arbiter.Agents.PreflightTest do
  # async: false — the CLAUDE_CODE_OAUTH_TOKEN fallback tests below mutate the
  # process-global OS environment (bd-2zigo1).
  use ExUnit.Case, async: false

  # bd-bw3466: no Ecto sandbox here, so ConfigDir's install-wide worker_env
  # scan can't read Workspace and logs a warning on every call. Expected in this
  # file; capture it so the run stays readable (logs still surface on failure).
  @moduletag :capture_log

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

    # bd-svczq4: a hung probe no longer *refuses* by default — a timeout is the
    # one outcome that says nothing about the credentials, and a nondeterministic
    # probe blocking valid work is what this ticket was filed about. It reports
    # `{:warn, ...}` with its own category so the caller can log and proceed; see
    # `Arbiter.Agents.PreflightProbeTest` for the `on_timeout: :refuse` lever.
    test "a hung probe warns with a pre-flight-specific reason, not a worker stall" do
      assert {:warn, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 5"],
                 probe_env: [],
                 timeout_ms: 80
               )

      assert reason.category == :preflight_timeout
      refute reason.category == :stalled
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

    # P4 (bd-cblemv) deleted the server-env fallback `oauth_token/1` used to
    # check: `spawn_env/1` no longer surfaces a server-process
    # CLAUDE_CODE_OAUTH_TOKEN as its *own* value. It now goes further than
    # merely omitting the pair — it emits an explicit `{..., false}` unset,
    # so a value inherited from the server process (which `Port.open`'s
    # `{:env, ...}` would otherwise extend rather than replace) can never
    # reach the spawned probe either. See `config_dir_test.exs` for the pair
    # shape; this file only needs to know it neutralises the leak.
    test "Claude.spawn_env/1 does not surface a server-process token — it unsets it" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

      assert List.keyfind(Claude.spawn_env([]), "CLAUDE_CODE_OAUTH_TOKEN", 0) ==
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
    end

    test "probe does NOT authenticate via a leaked install-wide CLAUDE_CODE_OAUTH_TOKEN" do
      # Before P4 this was a genuine incident (bd-6umoh9): a server-process
      # CLAUDE_CODE_OAUTH_TOKEN reached the probe via Port.open's ambient
      # inheritance regardless of what `spawn_env/1` returned. P4 closes it —
      # `spawn_env/1`'s explicit unset pair now strips the inherited value
      # before the port ever spawns, so a workspace-less probe with no
      # provider account carries no token at all, even when one is set on
      # the arbiter server's own process.
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

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
