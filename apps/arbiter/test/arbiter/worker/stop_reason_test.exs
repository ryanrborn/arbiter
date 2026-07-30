defmodule Arbiter.Worker.StopReasonTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.StopReason

  describe "classify/2 — auth expiry (provider-agnostic)" do
    test "Claude 401 / invalid authentication credentials" do
      reason =
        StopReason.classify(1, [
          "starting",
          "API Error: 401 Invalid authentication credentials"
        ])

      assert reason.category == :auth_expired
      assert reason.exit_status == 1
      assert reason.remediation =~ "Re-authenticate"
    end

    test "OAuth-expiry phrasing" do
      reason = StopReason.classify(1, ["your session has expired, please log in"])
      assert reason.category == :auth_expired
    end

    test "Gemini API key not valid" do
      reason = StopReason.classify(1, ["error: API key not valid. Please pass a valid API key."])
      assert reason.category == :auth_expired
    end

    test "auth wins over a non-zero exit code (specific beats generic)" do
      # Exit 1 alone would be :crashed; the 401 signature refines it to auth.
      reason = StopReason.classify(1, ["401 unauthorized"])
      assert reason.category == :auth_expired
    end

    test "auth wins even on a clean (0) exit when the CLI printed the error" do
      reason = StopReason.classify(0, ["invalid authentication credentials"])
      assert reason.category == :auth_expired
    end
  end

  describe "classify/2 — credit / rate limit" do
    test "insufficient credit balance" do
      reason = StopReason.classify(1, ["Your credit balance is too low to run this request."])
      assert reason.category == :credit_exhausted
      assert reason.remediation =~ "Top up"
    end

    test "out of tokens / quota exceeded" do
      assert StopReason.classify(1, ["you are out of credits"]).category == :credit_exhausted

      assert StopReason.classify(1, ["quota exceeded for this project"]).category ==
               :credit_exhausted
    end

    test "429 / rate limited / overloaded" do
      assert StopReason.classify(1, ["HTTP 429 Too Many Requests"]).category == :rate_limited
      assert StopReason.classify(1, ["the API is currently overloaded"]).category == :rate_limited

      assert StopReason.classify(1, ["RESOURCE_EXHAUSTED: rate limit"]).category ==
               :rate_limited
    end

    test "auth outranks credit when both appear" do
      reason =
        StopReason.classify(1, ["401 invalid authentication credentials", "credit balance"])

      assert reason.category == :auth_expired
    end
  end

  describe "classify/2 — gateway / proxy errors (bd-298jz0)" do
    test "proxy_error body from the local Anthropic proxy (502)" do
      reason =
        StopReason.classify(1, [
          ~s({"error":{"type":"proxy_error","message":"upstream unreachable"}})
        ])

      assert reason.category == :gateway_error
      assert reason.summary =~ "gateway"
      assert reason.remediation =~ "Auto-resuming"
    end

    test "plain 502 in output" do
      reason = StopReason.classify(1, ["HTTP 502 Bad Gateway"])
      assert reason.category == :gateway_error
    end

    test "upstream timeout phrase" do
      reason = StopReason.classify(1, ["upstream connection timeout"])
      assert reason.category == :gateway_error
    end

    test "overloaded 503 from Anthropic is still rate_limited (not gateway)" do
      # Anthropic returns 529/503 + "overloaded" — that phrase is in the rate-limit
      # signature which is checked first; gateway_error only catches infra-level
      # transport failures that don't carry the overloaded text.
      reason = StopReason.classify(1, ["HTTP 503 the API is currently overloaded"])
      assert reason.category == :rate_limited
    end

    test "gateway_error label is compact" do
      reason = StopReason.classify(1, ["proxy_error"])
      assert StopReason.label(reason) == "gateway error (proxy/upstream) (exit 1)"
    end
  end

  describe "classify/2 — signals / crashes / clean exit" do
    test "128+N exit band maps to a kill signal" do
      # 137 = 128 + 9 (SIGKILL)
      reason = StopReason.classify(137, ["worker doing things"])
      assert reason.category == :killed
      assert reason.signal == 9
      assert reason.summary =~ "signal 9"
    end

    test "SIGTERM (143 = 128+15)" do
      reason = StopReason.classify(143, [])
      assert reason.category == :killed
      assert reason.signal == 15
    end

    test "plain non-zero exit with no signature is a crash" do
      reason = StopReason.classify(1, ["error: unknown option '--reasoning-effort'"])
      assert reason.category == :crashed
      assert reason.exit_status == 1
      assert reason.signal == nil
    end

    test "clean exit with no arb done is exited_without_done" do
      reason = StopReason.classify(0, ["did some work", "but never finished"])
      assert reason.category == :exited_without_done
      assert reason.exit_status == 0
    end

    test "nil exit (watchdog) is a stall" do
      reason = StopReason.classify(nil, ["thinking..."])
      assert reason.category == :stalled
      assert reason.exit_status == nil
    end
  end

  describe "classify/2 — spawn_exec_failed (bd-11abk2, zero-output crashes)" do
    test "exit 7 with zero output is classified as the E2BIG/MAX_ARG_STRLEN case" do
      reason = StopReason.classify(7, [])
      assert reason.category == :spawn_exec_failed
      assert reason.summary =~ "E2BIG"
      assert reason.summary =~ "MAX_ARG_STRLEN"
      assert reason.remediation =~ "harness bug"
    end

    test "exit 7 with only blank/whitespace lines still counts as zero output" do
      reason = StopReason.classify(7, ["", "   ", "\n"])
      assert reason.category == :spawn_exec_failed
    end

    test "any other non-zero exit with zero output is a generic spawn failure" do
      reason = StopReason.classify(127, [])
      assert reason.category == :spawn_exec_failed
      assert reason.summary =~ "code 127"
      refute reason.summary =~ "E2BIG"
    end

    test "exit 7 with actual captured output is NOT spawn_exec_failed" do
      reason = StopReason.classify(7, ["something the process actually printed"])
      assert reason.category == :crashed
    end

    test "a clean (0) exit with no output is still exited_without_done, not spawn_exec_failed" do
      reason = StopReason.classify(0, [])
      assert reason.category == :exited_without_done
    end

    test "label is compact for the spawn_exec_failed category" do
      reason = StopReason.classify(7, [])
      assert StopReason.label(reason) == "spawn failed (no output — exec error) (exit 7)"
    end
  end

  # bd-80kdgy: codex 0.142.5 changed `exec --json`'s schema, so every event fell
  # through the parser's catch-all. The run exited 0 with an empty transcript and
  # was reported as a clean, no-diff success. The parser now emits a visible
  # drift marker; classify/2 must turn that marker into a HARNESS-bug verdict,
  # because "re-dispatch" (the :exited_without_done remediation) would fail
  # identically forever.
  describe "classify/2 — agent stream schema drift (bd-80kdgy)" do
    test "a clean exit whose transcript is drift warnings is a harness bug" do
      lines = [
        "⚠ codex: unrecognized stream event \"thread.started\" — this Arbiter build " <>
          "does not understand your codex CLI's --json schema"
      ]

      reason = StopReason.classify(0, lines)
      assert reason.category == :stream_schema_drift
      assert reason.summary =~ "schema"
      assert reason.remediation =~ "harness"
      assert StopReason.label(reason) =~ "schema"
    end

    test "drift outranks the generic exited-without-done verdict" do
      refute StopReason.classify(0, ["⚠ codex: unrecognized stream event \"turn.started\""]).category ==
               :exited_without_done
    end

    test "a normal clean exit is still :exited_without_done" do
      assert StopReason.classify(0, ["all finished"]).category == :exited_without_done
    end
  end

  describe "classify/2 — context autocompact thrash (bd-8cn795)" do
    test "the exact autocompact-thrash message classifies as :context_thrash" do
      lines = [
        "reading apps/arbiter/lib/arbiter/workflows/review_patrol.ex",
        "Autocompact is thrashing: the context refilled to the limit within 3 " <>
          "turns of the previous compact, 3 times in a row"
      ]

      reason = StopReason.classify(1, lines)

      assert reason.category == :context_thrash
      assert reason.summary =~ "context"
      assert reason.remediation =~ "1M"
      assert StopReason.label(reason) =~ "context"
    end

    test "matches case-insensitively and regardless of exact exit code" do
      assert StopReason.classify(1, ["autocompact is thrashing"]).category == :context_thrash
      assert StopReason.classify(0, ["AUTOCOMPACT IS THRASHING"]).category == :context_thrash
    end

    test "context-thrash wins over the generic crashed/exited-without-done fallback" do
      refute StopReason.classify(1, ["autocompact is thrashing"]).category == :crashed

      refute StopReason.classify(0, ["autocompact is thrashing"]).category ==
               :exited_without_done
    end

    test "an unrelated non-zero exit with no thrash signature is still :crashed" do
      refute StopReason.classify(1, ["some other failure"]).category == :context_thrash
    end

    # bd-6nr53z / run c88c77b0-2927-41ec-b582-6210538a43b3: the worker's own
    # earlier tool output (grepping arbiter/github.ex, which is riddled with
    # "rate-limit" identifiers/comments) sat in the same tail window as the
    # terminal autocompact-thrash message. classify/2 stamped `:rate_limited`
    # instead of `:context_thrash` because the rate-limit signature was
    # checked (and won) before the thrash signature ever got a look. The true
    # terminal signal — the CLI's own loop detector — must win regardless of
    # incidental "rate-limit"-shaped prose earlier in the captured output.
    test "context-thrash outranks incidental rate-limit-shaped text earlier in the tail (c88c77b0 regression)" do
      lines = [
        "apps/arbiter/lib/arbiter/github.ex:20:      rate-limit cache in `:persistent_term` keyed by",
        "apps/arbiter/lib/arbiter/github.ex:44:  @rate_limit_key :arbiter_github_rate_limit",
        "apps/arbiter/lib/arbiter/github.ex:241:  Return the most recent rate-limit state observed from any GitHub response,",
        "apps/arbiter/lib/arbiter/github.ex:445:  defp update_rate_limit(headers) do",
        "apps/arbiter/lib/arbiter/agents/claude.ex:27:      `ANTHROPIC_API_KEY` for the spawn — addresses rate-limit relief",
        "Autocompact is thrashing: the context refilled to the limit within 3 turns of the " <>
          "previous compact, 3 times in a row. A file being read or a tool output is likely " <>
          "too large for the context window. Try reading in smaller chunks, or use /clear to start fresh.",
        "⚙ claude session error · 523.8s · $4.6105"
      ]

      reason = StopReason.classify(1, lines)

      assert reason.category == :context_thrash
      refute reason.category == :rate_limited
    end
  end

  describe "classify/2 — rate-limit signature requires a positive signal (bd-6nr53z)" do
    test "bare mentions of 'rate-limit' in source-code prose do NOT classify as rate_limited" do
      lines = [
        "apps/arbiter/lib/arbiter/github.ex:20:      rate-limit cache in `:persistent_term` keyed by",
        "apps/arbiter/lib/arbiter/github.ex:44:  @rate_limit_key :arbiter_github_rate_limit",
        "apps/arbiter/lib/arbiter/github/error.ex:8:    * :forbidden — 403, token lacks scope or rate-limit hit",
        "error: unknown option '--reasoning-effort'"
      ]

      reason = StopReason.classify(1, lines)

      refute reason.category == :rate_limited
      assert reason.category == :crashed
    end

    test "a genuine 429 payload still classifies as rate_limited" do
      assert StopReason.classify(1, ["API Error: 429 {\"type\":\"rate_limit_error\"}"]).category ==
               :rate_limited
    end
  end

  describe "label/1 and to_map/1" do
    test "label is a compact one-liner with the exit code" do
      assert StopReason.classify(1, ["401"]) |> StopReason.label() ==
               "credentials expired (exit 1)"

      assert StopReason.classify(137, []) |> StopReason.label() == "killed by signal 9 (exit 137)"
      assert StopReason.classify(nil, []) |> StopReason.label() == "stalled (no output)"
    end

    test "to_map is a plain serializable map" do
      map = StopReason.classify(1, ["401"]) |> StopReason.to_map()
      assert map.category == :auth_expired
      assert is_binary(map.summary)
      assert map.exit_status == 1
      refute Map.has_key?(map, :__struct__)
    end
  end
end
