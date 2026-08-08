defmodule Arbiter.Loop.FailureClassifierTest do
  # Pure module — no DB, no I/O. Fully synchronous.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.FailureClassifier, as: FC

  describe "operational allowlist (label-only, no transcript)" do
    test "server restarted is operational" do
      r = FC.classify("server restarted", [])
      assert r.class == :operational
      assert r.subcategory == :server_restart
      assert r.label_class == :operational
      refute r.reclassified
    end

    test "awaiting_review_timeout is operational" do
      assert FC.classify("{:awaiting_review_timeout, 30}", []).class == :operational
    end

    test "auth failure is operational" do
      r = FC.classify("agent could not authenticate (credentials expired or invalid)", [])
      assert r.class == :operational
      assert r.subcategory == :auth_failure
    end

    test "github merge_failed is operational" do
      reason =
        "{:merge_failed, %Arbiter.Mergers.Github.Error{kind: :validation_failed, status: 422}}"

      assert FC.classify(reason, []).class == :operational
      assert FC.classify(reason, []).subcategory == :merge_failed
    end
  end

  describe "agent-quality allowlist (label-only)" do
    test ":review_gate_rejected is agent-quality" do
      r = FC.classify(":review_gate_rejected", [])
      assert r.class == :agent_quality
      assert r.subcategory == :review_gate_rejected
    end

    test "never signalled arb done is agent-quality" do
      r =
        FC.classify(
          "agent exited cleanly but never signalled `arb done` (quit before completing)",
          []
        )

      assert r.class == :agent_quality
      assert r.subcategory == :never_signalled_done
    end

    test ":uncommitted_at_completion / :no_commits_at_completion are agent-quality" do
      assert FC.classify(":uncommitted_at_completion", []).class == :agent_quality
      assert FC.classify(":no_commits_at_completion", []).class == :agent_quality
    end

    test ":secret_in_commit is agent-quality" do
      assert FC.classify(":secret_in_commit", []).class == :agent_quality
    end

    test "explicit context-thrash reason is agent-quality/context_exhaustion" do
      reason =
        "agent's context window thrashed (autocompact refilled immediately, several cycles in a row) before completing any work"

      r = FC.classify(reason, [])
      assert r.class == :agent_quality
      assert r.subcategory == :context_exhaustion
    end
  end

  describe "unclassified & excluded reasons are not force-bucketed" do
    test "an unknown reason is :unclassified, not silently operational" do
      r = FC.classify("some brand new failure nobody allowlisted", [])
      assert r.class == :unknown
      assert r.subcategory == :unclassified
    end

    test ":simulated_failure is excluded from the corpus" do
      assert FC.classify(":simulated_failure", []).class == :excluded
    end

    test "nil failure_reason is unclassified, never operational" do
      assert FC.classify(nil, []).class == :unknown
    end
  end

  describe "transcript corroboration overrides an operational label (the c88c77b0 lesson)" do
    @autocompact "Autocompact is thrashing: the context refilled to the limit within 3 turns of the previous compact, 3 times in a row. A file being read or a tool output is likely too large for the context window."
    @session_error "⚙ claude session error · 523.8s · $4.6105"

    test "rate-limited label + autocompact-thrash transcript => agent-quality/context_exhaustion, reclassified" do
      r =
        FC.classify(
          "agent was rate-limited / the API was overloaded",
          [@autocompact, @session_error]
        )

      assert r.class == :agent_quality
      assert r.subcategory == :context_exhaustion
      # The label alone would have said operational — record the disagreement.
      assert r.label_class == :operational
      assert r.reclassified
      assert r.corroborated
    end

    test "a BARE claude session error (no autocompact) does NOT reclassify — it is non-discriminating" do
      # On the real corpus a bare `claude session error` ends nearly every
      # failed session regardless of cause. Keying context-exhaustion on it
      # would reclassify server restarts and auth failures as agent-quality.
      # Only the autocompact fingerprint is decisive, so the rate-limited label
      # is left operational here.
      r = FC.classify("agent was rate-limited / the API was overloaded", [@session_error])
      assert r.class == :operational
      refute r.reclassified
    end

    test "reading arbiter's own quota source code does not count as an API error" do
      # This is exactly what fooled the label on c88c77b0: the worker was
      # grepping quota modules, so the transcript is full of 'quota'/'rate' — as
      # file paths, not error payloads. Must still classify context-exhaustion.
      noise = [
        "apps/arbiter/lib/arbiter/quota/anthropic_quota.ex",
        "apps/arbiter_cli/lib/arbiter_cli/cmd/quota.ex",
        @autocompact,
        @session_error
      ]

      r = FC.classify("agent was rate-limited / the API was overloaded", noise)
      assert r.subcategory == :context_exhaustion
      assert r.reclassified
    end

    test "a GENUINE API overload signal keeps the operational label (no false reclassify)" do
      genuine = [
        "API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
      ]

      r = FC.classify("agent was rate-limited / the API was overloaded", genuine)
      assert r.class == :operational
      assert r.subcategory == :rate_limited
      refute r.reclassified
    end
  end

  describe "corroboration status is reported for operational labels" do
    test "operational label with no transcript is flagged corroboration :unavailable" do
      r = FC.classify("server restarted", [])
      assert r.corroboration == :unavailable
      refute r.corroborated
    end

    test "operational label with a clean transcript is corroborated" do
      r = FC.classify("server restarted", ["worker resumed", "⚙ server restarting for deploy"])
      assert r.class == :operational
      assert r.corroborated
      assert r.corroboration == :agree
    end
  end

  describe "transcript corroboration overrides exit-code-1 to detect proxy 5xx" do
    test "exit-code-1 + PendingMigrationError transcript => operational/proxy_5xx (the bd-44gk10 case)" do
      # This is the exact case from bd-44gk10: the proxy had un-run migrations,
      # every call returned 503.
      transcript = [
        "Agent exited with status 1",
        "** (Phoenix.Ecto.PendingMigrationError) The following migrations have not run:",
        "** (Phoenix.Ecto.PendingMigrationError) ...tables are missing. Run 'mix ecto.create' or 'mix ecto.migrate' to fix.",
        "⚙ claude session error · 12.3s · $0.50"
      ]

      r = FC.classify("agent subprocess crashed (exit code 1)", transcript)
      assert r.class == :operational
      assert r.subcategory == :proxy_5xx
      # The label alone would have said unknown — record the override.
      assert r.label_class == :unknown
      assert r.reclassified
      assert r.corroborated
    end

    test "the two cited runs from bd-8mtb0q both classify as operational/proxy_5xx" do
      # Run 1: bd-bvxdy9, 08-07 13:37
      r1 =
        FC.classify(
          "agent subprocess crashed (exit code 1)",
          [
            "Calling Anthropic proxy...",
            "** (Phoenix.Ecto.PendingMigrationError) you must run migrations",
            "HTTP 503 response"
          ]
        )

      assert r1.class == :operational
      assert r1.subcategory == :proxy_5xx

      # Run 2: bd-bvxdy9, 08-06 21:48
      r2 =
        FC.classify(
          "agent subprocess crashed (exit code 1)",
          [
            "Proxy error occurred",
            "** (DBConnection.ConnectionError) connection failed to database",
            "Retrying connection..."
          ]
        )

      assert r2.class == :operational
      assert r2.subcategory == :proxy_5xx
    end

    test "exit-code-1 with no proxy error stays unknown (not a catch-all for all exit-1s)" do
      # This is the critical guard: a bare exit-1 ends many runs for unrelated
      # reasons. We must NOT make exit-1 an operational catch-all.
      transcript = [
        "Agent exited with status 1",
        "SomeError: unexpected problem",
        "⚙ claude session error · 5.2s · $0.30"
      ]

      r = FC.classify("agent subprocess crashed (exit code 1)", transcript)
      assert r.class == :unknown
      assert r.subcategory == :unclassified
      refute r.reclassified
    end

    test "proxy 5xx error without exit-code-1 label is still operational/proxy_5xx" do
      transcript = [
        "Calling proxy...",
        "** (Phoenix.Ecto.PendingMigrationError) you must run migrations",
        "HTTP 503 response from service"
      ]

      r = FC.classify("some other label", transcript)
      assert r.class == :operational
      assert r.subcategory == :proxy_5xx
      assert r.reclassified
    end
  end

  describe "helpers" do
    test "context_exhaustion?/1 keys on the autocompact fingerprint, not a bare session error" do
      assert FC.context_exhaustion?([@autocompact])
      assert FC.context_exhaustion?(["the agent's context window thrashed repeatedly"])
      # A bare session error is non-discriminating on the real corpus.
      refute FC.context_exhaustion?([@session_error])
      refute FC.context_exhaustion?(["all good", "✓ arb done"])
    end

    test "api_error_signal?/1 matches error payloads, not source paths" do
      assert FC.api_error_signal?(["API Error: 429 overloaded_error"])
      refute FC.api_error_signal?(["apps/arbiter/lib/arbiter/quota/anthropic_quota.ex"])
    end

    test "proxy_5xx?/1 detects Arbiter proxy infrastructure 5xx errors" do
      assert FC.proxy_5xx?(["** (Phoenix.Ecto.PendingMigrationError) tables missing"])
      assert FC.proxy_5xx?(["** (DBConnection.ConnectionError) connection failed"])
      assert FC.proxy_5xx?(["HTTP 503"])
      assert FC.proxy_5xx?(["HTTP 500"])
      assert FC.proxy_5xx?(["HTTP 502"])
      refute FC.proxy_5xx?(["HTTP 404"])
      refute FC.proxy_5xx?(["HTTP 429"])
      refute FC.proxy_5xx?(["some random error"])
    end
  end
end
