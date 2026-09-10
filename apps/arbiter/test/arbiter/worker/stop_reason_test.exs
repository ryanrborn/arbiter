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

  describe "classify/2 — 5h usage-limit exhaustion (bd-3hr6g2)" do
    test "Claude CLI's usage-limit-reached message, with a reset epoch" do
      reason = StopReason.classify(1, ["Claude AI usage limit reached|1735689600"])

      assert reason.category == :quota_exhausted
      assert reason.retry_after == DateTime.from_unix!(1_735_689_600)
      assert reason.remediation =~ "resets"
    end

    test "usage-limit-reached message with no parseable reset timestamp" do
      reason = StopReason.classify(1, ["5-hour limit reached, try again later"])

      assert reason.category == :quota_exhausted
      assert reason.retry_after == nil
    end

    test "does not fall into the generic credit/quota-exceeded bucket" do
      # "usage limit reached" carries no "credit"/"quota exceeded"-shaped words,
      # so it must not be swallowed by the broader @credit_signature.
      reason = StopReason.classify(1, ["Claude AI usage limit reached|1735689600"])
      refute reason.category == :credit_exhausted
    end

    test "wins over a bare non-zero exit (specific beats generic :crashed)" do
      reason = StopReason.classify(1, ["usage limit reached"])
      assert reason.category == :quota_exhausted
    end

    # bd-3wgdie: the phrase must lead its line (module docstrings, grep hits,
    # and other tool output the worker merely read embed it mid-line) unless
    # the reset-epoch suffix is present.
    test "does not false-match the phrase quoted mid-line in a file the worker read" do
      reason =
        StopReason.classify(1, [
          "    25\t      was reached (\"Claude AI usage limit reached\", \"5-hour limit reached\"),"
        ])

      refute reason.category == :quota_exhausted
    end

    test "does not false-match a grep-style prefixed line" do
      reason =
        StopReason.classify(1, [
          "stop_reason.ex:25:      (\"Claude AI usage limit reached\")"
        ])

      refute reason.category == :quota_exhausted
    end

    test "still matches when the phrase leads the line after only whitespace" do
      reason = StopReason.classify(1, ["   Claude AI usage limit reached"])
      assert reason.category == :quota_exhausted
    end

    test "the reset-epoch suffix matches even without line anchoring" do
      reason =
        StopReason.classify(1, [
          "some prefix noise usage limit reached|1735689600"
        ])

      assert reason.category == :quota_exhausted
    end

    # bd-6dxit2: the Claude CLI changed the wording it emits when the 5h plan
    # allowance is spent — it now says "You've hit your session limit · resets
    # <time>" and exits 1 within a second, never running the agent. The old
    # signature only knew "usage limit reached" / "5-hour limit reached", so
    # these refusals classified as :crashed. That mattered: :crashed is not an
    # infra-failure category, so ReviewGate re-prompted a reviewer that could
    # not possibly run and then reported "no parseable VERDICT line" — a review
    # that never happened, blamed on the reviewer (see review_gate_test.exs).
    test "current CLI wording: \"You've hit your session limit\"" do
      reason =
        StopReason.classify(1, [
          "⚙ claude session started (model claude-opus-5)",
          "You've hit your session limit · resets 4:50am (America/New_York)",
          "⚙ claude session error · 0.7s · $0.0"
        ])

      assert reason.category == :quota_exhausted
    end

    test "current CLI wording with a typographic apostrophe" do
      reason = StopReason.classify(1, ["You\u2019ve hit your session limit · resets 4:50am"])
      assert reason.category == :quota_exhausted
    end

    test "\"hit your usage limit\" phrasing also classifies as quota" do
      reason = StopReason.classify(1, ["You've hit your usage limit · resets 9pm"])
      assert reason.category == :quota_exhausted
    end

    test "bare \"session limit reached\" leading its line classifies as quota" do
      reason = StopReason.classify(1, ["  Session limit reached"])
      assert reason.category == :quota_exhausted
    end

    # bd-3wgdie's false-match guard must survive the new wording: source and
    # tool output the reviewer merely *read* must not park a run for 5 hours.
    test "does not false-match the session-limit wording quoted mid-line" do
      reason =
        StopReason.classify(1, [
          "stop_reason.ex:180:    | you\u2019ve hit your session limit",
          "    62\t  # matches \"You've hit your session limit\" from the CLI"
        ])

      refute reason.category == :quota_exhausted
    end

    # bd-cfhj7z: run 7e9e5ea5 (task vs-1vd2hp, Fable, 2026-09-08). The worker
    # burned its whole 5h window in ~12 minutes and was cut off mid-report; the
    # phrase led four separate lines of the durable log, yet Arbiter recorded
    # "agent subprocess crashed (exit code 1)". This is the verbatim five-line
    # tail from that run, including the `claude session error` lines that follow
    # the phrase — those trailing lines are the reason the tail is quoted in
    # full: the last line of the log is NOT the quota phrase, so the detector
    # has to find it inside the window rather than at the very end.
    test "verbatim five-line tail from run 7e9e5ea5 classifies as quota" do
      reason =
        StopReason.classify(1, [
          "You've hit your session limit \u00b7 resets 3:30am (America/New_York)",
          "\u2699 claude session started (model claude-fable-5-1)",
          "You've hit your session limit \u00b7 resets 3:30am (America/New_York)",
          "\u2699 claude session error \u00b7 674.5s \u00b7 $19.6159",
          "\u2699 claude session error \u00b7 0.4s \u00b7 $19.6159"
        ])

      assert reason.category == :quota_exhausted
      assert reason.summary =~ "usage limit"
      # The :crashed remediation this used to get ("check the captured stderr,
      # then re-dispatch") is exactly the wrong advice for an exhausted window.
      refute reason.remediation =~ "stderr"
    end

    # bd-cfhj7z / bd-3wgdie: the negative fixture is this ticket's own prose --
    # a realistic sample of text a worker could read while working the ticket.
    # Note the deliberate limit: the ticket ALSO quotes the raw log verbatim in
    # a fenced block, where the phrase does lead its line. Those lines are
    # byte-identical to real CLI output, so no line-anchored matcher can tell
    # them apart; the anchor buys us the prose case, which is the common one.
    test "does not false-match this ticket's own prose (bd-cfhj7z description)" do
      reason =
        StopReason.classify(1, [
          "1. `@quota_signature` gains a line-leading alternative matching the",
          "   observed wording (`you've hit your session limit`, tolerant of the",
          "   typographic vs ASCII apostrophe \u2014 the CLI emits `\u2019`, and a naive",
          "   `'` will silently fail to match). Anchored the same way the existing",
          "   alternatives are; no unanchored variant is added.",
          "bd-3wgdie already established that an unanchored quota phrase",
          "false-matches a worker's own tool output \u2014 and `:quota_exhausted`",
          "remediation is \"wait\", so a false positive costs a multi-hour park."
        ])

      refute reason.category == :quota_exhausted
      # Review round 1, finding 3, recorded honestly rather than papered over:
      # this fixture does NOT land on :crashed. The prose quotes the atom
      # `:quota_exhausted`, which trips the pre-existing *unanchored*
      # `@credit_signature` alternative `(quota|billing)…(exceeded|exhausted)`.
      # The refute above is what criterion 3 asked for and passes on its own
      # terms, but pinning the actual category keeps a future reader from
      # reading it as proof the line anchor is what saved us here.
      assert reason.category == :credit_exhausted
    end

    # ...so this is the assertion that actually isolates the line anchor: the
    # same phrase, quoted mid-line, with nothing else in the tail for another
    # signature to catch. It must fall all the way through to :crashed.
    test "the phrase quoted mid-line with no other signal falls through to :crashed" do
      reason =
        StopReason.classify(1, [
          "   observed wording (`you've hit your session limit`, tolerant of the",
          "   typographic vs ASCII apostrophe \u2014 the CLI emits `\u2019`)"
        ])

      assert reason.category == :crashed
      assert reason.retry_after == nil
    end

    # bd-cfhj7z scope note: detection must not assume repetition. Run 7e9e5ea5
    # showed the phrase four times, but a corroborating run showed it exactly
    # once in a 1067-line log. One occurrence, buried behind a long tail of
    # ordinary worker chatter, is enough.
    test "a single occurrence behind a long tail still classifies as quota" do
      chatter = for i <- 1..1_100, do: "  #{i} | ordinary worker output line"

      lines =
        chatter ++
          [
            "You've hit your session limit \u00b7 resets 3:30am (America/New_York)",
            "\u2699 claude session error \u00b7 0.4s \u00b7 $19.6159"
          ]

      assert StopReason.classify(1, lines).category == :quota_exhausted
    end

    # bd-cfhj7z scope note: the wording is not Fable-specific — Sonnet emits the
    # identical form. Nothing in the signature is model-aware; this pins that.
    test "the same wording from a Sonnet session classifies identically" do
      reason =
        StopReason.classify(1, [
          "\u2699 claude session started (model claude-sonnet-5)",
          "You\u2019ve hit your session limit \u00b7 resets 11:15pm (America/New_York)",
          "\u2699 claude session error \u00b7 1.2s \u00b7 $0.0"
        ])

      assert reason.category == :quota_exhausted
    end
  end

  # bd-cfhj7z: the CLI reports the reset as a human-readable wall clock in an
  # IANA zone (`resets 3:30am (America/New_York)`), not the `|<epoch>` suffix
  # `@quota_reset_signature` knows. Without this the category was right but the
  # wait was always the blanket 5h default, even when the window reset in 10
  # minutes.
  describe "retry_after — wall-clock reset form (bd-cfhj7z)" do
    test "resolves a reset later today to today" do
      # 01:00 local, reset at 03:30 local, host at UTC-4.
      local_now = ~N[2026-09-08 01:00:00]
      offset = -4 * 3600

      assert StopReason.wallclock_reset_utc(local_now, offset, 3, 30) ==
               ~U[2026-09-08 07:30:00Z]
    end

    test "resolves a reset already past today to tomorrow" do
      # 23:50 local, reset at 03:30 local => tomorrow, host at UTC-4.
      local_now = ~N[2026-09-08 23:50:00]
      offset = -4 * 3600

      assert StopReason.wallclock_reset_utc(local_now, offset, 3, 30) ==
               ~U[2026-09-09 07:30:00Z]
    end

    # Review round 1, finding 1. `classify/2` runs at session *exit*, which can
    # be many minutes after the CLI printed the phrase -- run 7e9e5ea5's own
    # tail says `674.5s`. A reset that elapsed inside that gap must not roll to
    # tomorrow: that would park the worker and its worktree for ~24h, strictly
    # worse than the 5h default the wall-clock path is meant to improve on.
    test "a reset 12 minutes in the past does not become a 24h wait" do
      # 03:42 local, reset was 03:30 local, host at UTC-4.
      local_now = ~N[2026-09-08 03:42:00]
      offset = -4 * 3600

      reset = StopReason.wallclock_reset_utc(local_now, offset, 3, 30)

      # The reset that just happened, not tomorrow's.
      assert reset == ~U[2026-09-08 07:30:00Z]
      # And therefore a wait the caller floors at 60s, not ~24h.
      assert Arbiter.Worker.quota_resume_backoff_ms(reset) == 60_000
    end

    test "a reset an hour or less in the past stays in the past" do
      # Exactly at the slack bound: 04:30 local against an 03:30 reset.
      assert StopReason.wallclock_reset_utc(~N[2026-09-08 04:30:00], 0, 3, 30) ==
               ~U[2026-09-08 03:30:00Z]

      # Just past it, the roll is back on.
      assert StopReason.wallclock_reset_utc(~N[2026-09-08 04:30:01], 0, 3, 30) ==
               ~U[2026-09-09 03:30:00Z]
    end

    # The other half of finding 1's guard: a roll that survives but lands
    # further out than the 5h window this wording describes means the date
    # guess was wrong, so the whole parse is declined and the pre-existing 5h
    # default stands -- never worse than before the branch.
    test "declines a reset further out than the window it can describe" do
      # On a host whose zone cannot be named this decline is the zone-mismatch
      # one instead; the assertion below holds either way, and CI/dev hosts here
      # do resolve a zone, so the horizon path is the one being exercised.
      zone = StopReason.host_time_zone_name()
      # Whatever the local hour is, this names the wall clock ~12h away.
      far = NaiveDateTime.add(NaiveDateTime.local_now(), 12 * 3600, :second)

      reason =
        StopReason.classify(1, [
          "You've hit your session limit \u00b7 resets #{wall_clock_12h(far)} (#{zone || "America/New_York"})"
        ])

      assert reason.category == :quota_exhausted
      assert reason.retry_after == nil
    end

    test "handles a positive UTC offset" do
      local_now = ~N[2026-09-08 01:00:00]

      assert StopReason.wallclock_reset_utc(local_now, 2 * 3600, 3, 30) ==
               ~U[2026-09-08 01:30:00Z]
    end

    test "a reset exactly now resolves to now, not a day out" do
      local_now = ~N[2026-09-08 03:30:00]

      assert StopReason.wallclock_reset_utc(local_now, 0, 3, 30) ==
               ~U[2026-09-08 03:30:00Z]
    end

    test "classify/2 parses the reset when the message zone is the host zone" do
      zone = StopReason.host_time_zone_name()
      # Named relative to now rather than as a fixed "3:30am": the horizon bound
      # from finding 1 declines a reset further out than the window this wording
      # can describe, so a hardcoded hour would pass or fail depending on what
      # time of day the suite runs.
      at = NaiveDateTime.add(NaiveDateTime.local_now(), 90 * 60, :second)

      reason =
        StopReason.classify(1, [
          "You've hit your session limit \u00b7 resets #{wall_clock_12h(at)} (#{zone || "America/New_York"})"
        ])

      assert reason.category == :quota_exhausted

      if zone do
        assert %DateTime{} = reason.retry_after
        # All modern IANA offsets are whole minutes, so the minute survives the
        # local->UTC conversion.
        assert reason.retry_after.minute == at.minute
        diff = DateTime.diff(reason.retry_after, DateTime.utc_now())
        assert diff > 0 and diff <= 90 * 60
        assert reason.remediation =~ "resets at"
      else
        assert reason.retry_after == nil
      end
    end

    # Review round 1, finding 2: a parenthetical the zone-name grammar cannot
    # span must decline, not silently fall through to "assume host-local" and
    # apply this host's offset to a wall clock written elsewhere.
    test "declines when the zone parenthetical is not an IANA name" do
      for rendering <- ["(UTC-04:00)", "(GMT+5:30)", "(UTC\u221204:00)", "(Pacific Time)"] do
        reason =
          StopReason.classify(1, [
            "You've hit your session limit \u00b7 resets 3:30am #{rendering}"
          ])

        assert reason.category == :quota_exhausted, "category for #{rendering}"
        assert reason.retry_after == nil, "retry_after for #{rendering}"
      end
    end

    # Review round 1, finding 2, at the edges a bounded raw-text class still
    # missed. Each of these leaves the *optional* zone group unmatched, so
    # `zone` comes back empty and the parse silently takes the "no zone named,
    # assume host-local" path -- applying this host's offset to a wall clock
    # that may have been written somewhere else. Anything trailing the time
    # that is not a closed parenthetical must decline instead.
    test "declines when text follows the time that is not a parseable zone" do
      # Well inside the horizon bound, so the only thing that can decline
      # these is the zone logic under test.
      at = NaiveDateTime.add(NaiveDateTime.local_now(), 30 * 60, :second)
      long = String.duplicate("Very_Long_Region/", 4) <> "Endsville"

      for trailing <- ["(America/New_York", "(#{long})", "()", "in about 12 hours"] do
        reason =
          StopReason.classify(1, [
            "You've hit your session limit \u00b7 resets #{wall_clock_12h(at)} #{trailing}"
          ])

        assert reason.category == :quota_exhausted, "category for #{trailing}"
        assert reason.retry_after == nil, "retry_after for #{trailing}"
      end
    end

    # The other side of that guard: declining on unaccounted trailing text must
    # not also kill the documented host-local path, which is a line whose reset
    # clause names no zone at all.
    test "a message with no zone parenthetical is still read as host-local" do
      at = NaiveDateTime.add(NaiveDateTime.local_now(), 30 * 60, :second)

      reason =
        StopReason.classify(1, [
          "You've hit your session limit \u00b7 resets #{wall_clock_12h(at)}"
        ])

      assert reason.category == :quota_exhausted
      assert %DateTime{} = reason.retry_after

      diff = DateTime.diff(reason.retry_after, DateTime.utc_now())
      assert diff > 0 and diff <= 3_600
    end

    test "declines when the message names a zone that is not the host zone" do
      reason =
        StopReason.classify(1, [
          "You've hit your session limit \u00b7 resets 3:30am (Antarctica/Troll)"
        ])

      # The category fix must not be coupled to the time parsing.
      assert reason.category == :quota_exhausted
      assert reason.retry_after == nil
    end

    test "a 12-hour boundary reset parses as midnight/noon" do
      # 06:00 local is well past the past-slack bound, so midnight rolls.
      assert StopReason.wallclock_reset_utc(~N[2026-09-08 06:00:00], 0, 0, 0) ==
               ~U[2026-09-09 00:00:00Z]

      assert StopReason.wallclock_reset_utc(~N[2026-09-08 06:00:00], 0, 12, 0) ==
               ~U[2026-09-08 12:00:00Z]
    end

    test "the epoch form still wins when both are present" do
      reason =
        StopReason.classify(1, [
          "Claude AI usage limit reached|1789000000",
          "You've hit your session limit \u00b7 resets 3:30am (America/New_York)"
        ])

      assert reason.category == :quota_exhausted
      assert reason.retry_after == DateTime.from_unix!(1_789_000_000)
    end

    test "12am and 12pm are parsed as 00:00 and 12:00" do
      phrase = "You've hit your session limit \u00b7 "

      assert StopReason.parse_wallclock(phrase <> "resets 12am (America/New_York)") ==
               {0, 0, "America/New_York"}

      assert StopReason.parse_wallclock(phrase <> "resets 12pm") == {12, 0, nil}
      assert StopReason.parse_wallclock(phrase <> "resets 9pm") == {21, 0, nil}
      assert StopReason.parse_wallclock(phrase <> "resets 3:30AM") == {3, 30, nil}
    end

    test "the reset clause is only read off the CLI's own phrase line" do
      # Prose merely mentioning a reset time must not become a retry_after.
      refute StopReason.parse_wallclock("the window resets 3:30am (America/New_York)")
      refute StopReason.parse_wallclock("  quoted: you've hit your session limit")
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

    test "quota_exhausted label and to_map carry the reset time" do
      reason = StopReason.classify(1, ["Claude AI usage limit reached|1735689600"])
      assert StopReason.label(reason) == "5h usage limit reached (exit 1)"

      map = StopReason.to_map(reason)
      assert map.category == :quota_exhausted
      assert map.retry_after == DateTime.from_unix!(1_735_689_600)
    end
  end

  # Renders a NaiveDateTime the way the CLI writes a reset ("3:30am"), so a
  # fixture can name a wall clock at a known offset from *now* instead of
  # hardcoding an hour that drifts in and out of the horizon bound depending
  # on what time the suite happens to run.
  defp wall_clock_12h(%NaiveDateTime{} = at) do
    {hour12, meridiem} =
      case at.hour do
        0 -> {12, "am"}
        12 -> {12, "pm"}
        h when h < 12 -> {h, "am"}
        h -> {h - 12, "pm"}
      end

    "#{hour12}:#{String.pad_leading(to_string(at.minute), 2, "0")}#{meridiem}"
  end
end
