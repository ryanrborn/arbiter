defmodule Arbiter.Worker.StopReason do
  @moduledoc """
  Classify *why* an worker's agent subprocess stopped.

  This module is the **classification** half of stalled-worker detection
  (bd-awi4nw). Detection itself keys on **process/port liveness** — the worker
  learns the subprocess is gone from the Erlang port's `{:exit_status, n}`
  message (or, for a silent hang, from a no-output watchdog), never from
  scraping stdout for a success/failure pattern. A crashed or flag-rejected
  agent emits nothing useful, so output is not a reliable *stop* signal.

  Once a stop is detected, *this* module looks at the exit status and the tail
  of captured output to put a human-actionable label on it. The exit
  status/signal is authoritative; the output signatures only refine the label
  (e.g. distinguishing an auth-expiry 401 from a generic non-zero crash) so the
  coordinator escalation carries the right remediation.

  ## Categories

    * `:auth_expired` — the agent CLI could not authenticate (401 / "invalid
      authentication credentials" / OAuth expiry). Remediation: re-authenticate.
      Distinct from a generic failure because the fix is operator credentials,
      not the task. Provider-agnostic (Claude OAuth, Gemini API key).
    * `:quota_exhausted` — the Claude CLI's own 5h (or 7d) plan usage-limit
      was reached ("Claude AI usage limit reached", "5-hour limit reached"),
      distinct from `:credit_exhausted` (bd-3hr6g2). Not a billing problem —
      the account has a *time-boxed* allowance that refills on a known
      schedule, so this is provider-imposed throttling, not agent or task
      failure. When the CLI reports a reset timestamp it is parsed into
      `retry_after`; remediation is to wait for the window to reset (or
      switch to a workspace/key not sharing the exhausted plan), never a
      re-dispatch against the same account.
    * `:credit_exhausted` — out of credits / insufficient balance / quota /
      billing. Remediation: top up credits or rotate to a funded key.
    * `:rate_limited` — 429 / rate-limit / overloaded / resource exhausted.
      Often transient; remediation is retry/backoff.
    * `:gateway_error` — 502 / 503 / upstream unreachable from the local
      Anthropic proxy (transient network blip between the harness and
      api.anthropic.com). Distinct from a rate-limit or auth failure: the
      session was healthy, the transport layer dropped the request.
      Remediation: auto-resume — the session context is intact, a retry should
      succeed once connectivity recovers.
    * `:context_thrash` — the agent CLI's own autocompact loop detector fired
      ("Autocompact is thrashing: the context refilled to the limit within N
      turns of the previous compact, N times in a row") and the session
      aborted before doing any real work (bd-8cn795). Distinct from a generic
      `:crashed`: the cause is a working set too large for the model's
      context window (whole-file reads of several 500-1100+ line modules, or
      a huge PR body / API dump), not a task or agent bug. Retrying
      identically reproduces it — the remediation is a bigger context window
      or narrower reads, not a re-dispatch.
    * `:killed` — terminated by a signal (the `sh` wrapper reports `128 + N`).
      External kill, OOM, host restart.
    * `:spawn_exec_failed` — non-zero exit with **zero captured output** at
      all — the child never ran, so it never got a chance to write anything.
      The canonical cause (bd-11abk2) is `execve()` failing before the
      process starts: exit 7 is Linux's E2BIG (a spliced argv element, almost
      always the prompt, exceeded the per-argument `MAX_ARG_STRLEN` =
      131 072-byte kernel limit). Distinct from `:crashed` because a crash
      normally leaves *some* stderr; a truly empty capture plus a non-zero
      status points at the exec step itself, not the agent's own logic —
      the remediation is a harness/argv fix, not a task re-dispatch.
    * `:crashed` — non-zero exit with no recognized signature. The
      flag-rejection proof case (`unknown option --reasoning-effort` → immediate
      non-zero exit) lands here unless its stderr matches a more specific
      signature.
    * `:exited_without_done` — clean exit (status 0) but the worker never
      emitted `arb done`. It quit early without completing the task.
    * `:async_wait_abandoned` — a *refinement* of `:exited_without_done`
      (bd-606zlr): the clean exit happened immediately after the agent armed
      an asynchronous wait — a `Monitor`, a `ScheduleWakeup`, or a
      backgrounded `Bash` — and then yielded the turn to await the
      notification. `claude --print` is non-interactive: the agent loop ends
      the instant a turn produces no tool call, so that notification can never
      be delivered — there is no session left to deliver it to. The agent was
      doing the *right* thing (recognising a command that won't finish inside
      the tool-call timeout) with a primitive this harness cannot honour.
      Distinct from a plain early quit because the remediation is a
      `--resume` carrying corrective guidance, never a re-dispatch: the
      worktree usually holds real, uncommitted work.
    * `:stalled` — no exit at all; the subprocess is alive but produced no
      output within the watchdog window (caller passes `exit_status: nil`).
    * `:missing_worktree` — the worker signalled `arb done` on a reviewable
      code directive but no per-task branch/worktree was ever provisioned, so
      there is nothing to integrate (bd-7pe74i). Not a subprocess-exit
      classification — synthesized by the completion path to refuse closing a
      task that produced no deliverable. Remediation: investigate why
      provisioning was skipped, then re-dispatch.
    * `:spawn_failed` — a step of `Arbiter.Worker.Dispatch.dispatch/2` AFTER
      `start_worker/3` failed (e.g. a transient network/VPN outage during the
      agent subprocess spawn, or a workflow-machine attach failure). Not a
      subprocess-exit classification — there is no port/process to exit,
      since the agent never got a chance to start (bd-bi5pn0). Distinct from
      `:exited_without_done`, which covers a port that opened then exited
      early. Synthesized by `Dispatch.dispatch/2` itself so the worker it just
      registered `:idle` does not zombie with no retry/escalate. Remediation:
      investigate the dispatch error (often transient connectivity), then
      re-dispatch.

  ## Provider-agnostic signatures

  The auth / credit / rate-limit signatures are matched case-insensitively
  against the captured output and cover both the Claude CLI and the
  Gemini/`agy` CLIs (e.g. Gemini's `RESOURCE_EXHAUSTED`, `API key not valid`).
  They are intentionally broad: a false *refinement* (labelling a crash as
  rate-limited) is far cheaper than burying an auth-expiry as a generic
  failure.
  """

  @typedoc "Classified stop category."
  @type category ::
          :auth_expired
          | :quota_exhausted
          | :credit_exhausted
          | :rate_limited
          | :gateway_error
          | :context_thrash
          | :killed
          | :spawn_exec_failed
          | :crashed
          | :stream_schema_drift
          | :exited_without_done
          | :async_wait_abandoned
          | :stalled
          | :missing_worktree
          | :spawn_failed

  @type t :: %__MODULE__{
          category: category(),
          summary: String.t(),
          remediation: String.t() | nil,
          exit_status: integer() | nil,
          signal: integer() | nil,
          retry_after: DateTime.t() | nil
        }

  @enforce_keys [:category, :summary]
  defstruct [:category, :summary, :remediation, :exit_status, :signal, :retry_after]

  # Output signatures. Ordered most-specific-first; the first hit wins so an
  # auth 401 isn't swallowed by the broader rate-limit pattern. Matched
  # case-insensitively against the joined output tail.
  @auth_signature ~r/
      \b401\b
    | invalid[ _]authentication[ _]credentials
    | invalid[ _]api[ _]key
    | api[ _]key[ _]not[ _]valid
    | authentication[ _]error
    | unauthorized
    | not[ _]authenticated
    | (oauth|token|credentials?|session)[^\n]{0,40}(expired|invalid|revoked)
    | please[ _](run|sign|log)[ _-]?in
    | \/login\b
  /ix

  # bd-3hr6g2: the Claude CLI's own plan usage-limit message, distinct from a
  # billing/credit failure — this is a time-boxed allowance, not an account
  # balance. Checked ahead of @credit_signature so "usage limit reached" isn't
  # swallowed by the generic quota wording below (it wouldn't match anyway,
  # but ordering keeps the two signatures independent as either evolves).
  # The CLI appends the reset time as a unix-epoch-seconds after a `|`
  # (`"Claude AI usage limit reached|1735689600"`); parsed opportunistically
  # by `retry_after_from/1` — its absence just means no reset time is known.
  #
  # bd-3wgdie: the bare phrase is NOT anchored — a worker whose last 80 output
  # lines happen to include a tool result or file read that quotes/discusses
  # this exact wording (e.g. this very module's docstring, or a grep hit) would
  # otherwise false-match and pay a 5h+ park instead of a fast fail (the
  # `:quota_exhausted` remediation is "wait", not "re-dispatch", so a false hit
  # is expensive). Require the phrase to lead its line (only whitespace before
  # it, as the CLI actually emits it standalone) UNLESS the `|<epoch>` reset
  # suffix is present, which is specific enough on its own — real prose
  # discussing the message doesn't happen to append a matching unix timestamp.
  #
  # bd-6dxit2: the CLI's current wording for the same condition is
  # `You've hit your session limit · resets 4:50am (America/New_York)` — it
  # never says "usage limit reached" any more. Runs refused this way exit 1
  # within a second having emitted three lines, so before this alternative was
  # added they classified as `:crashed`: a generic non-zero exit whose
  # remediation is "re-dispatch". That misroute is what made ReviewGate re-prompt
  # a reviewer that could not run and then report "no parseable VERDICT line"
  # (the reviewer's fault) instead of "the account is out of 5h allowance".
  # Any apostrophe form the CLI may emit is accepted (`.{0,3}` spans a plain
  # `'` or a 3-byte UTF-8 `\u2019`; the regex carries no /u flag), and the line-leading
  # anchor from bd-3wgdie applies here too so quoting this wording in source or
  # tool output cannot buy a 5h park.
  # bd-cfhj7z: the four `usage limit reached` alternatives are RETAINED, kept
  # defensively rather than confirmed still-live — a scan of every run in the
  # live DB whose tail contains "limit reached" (14 runs, 2026-07-07..2026-09-09)
  # turned up no CLI emission of that wording at line start, only Arbiter's own
  # log line and workers grepping this repo's fixtures. Absence of a recent hit
  # is not proof an older pinned CLI build never emits it, so they stay.
  @quota_signature ~r/
      ^[ \t]*(claude[ _]ai[ _])?usage[ _]limit[ _]reached
    | ^[ \t]*5[ -]hour[ _]limit[ _]reached
    | ^[ \t]*5h[ _]limit[ _]reached
    | usage[ _]limit[ _]reached\|\d+
    | ^[ \t]*you.{0,3}ve[ ]hit[ ]your[ ](session|usage)[ ]limit
    | ^[ \t]*(session|usage)[ _]limit[ _]reached
  /mix

  @quota_reset_signature ~r/usage[ _]limit[ _]reached\|(\d+)/i

  # bd-cfhj7z: the CLI build seen in run 7e9e5ea5 reports the reset as a
  # human-readable *local wall clock* with an IANA zone name
  # (`resets 3:30am (America/New_York)`) rather than the `|<epoch>` suffix
  # `@quota_reset_signature` knows. `retry_after_from/1` therefore returned nil
  # and `Arbiter.Worker.quota_resume_backoff_ms/1` fell back to its blanket 5h
  # default — parking a worker and its worktree for five hours even when the
  # window was ten minutes from resetting.
  #
  # The reset clause is only read off the CLI's own phrase line (the same
  # bd-3wgdie line-leading anchor `@quota_signature` uses). Reading it from
  # anywhere in the tail would let prose that merely mentions a reset time
  # *shorten* a park, which is the more dangerous direction of the two.
  #
  # Review round 1, finding 2: nothing after the meridiem is parsed *inside* this
  # regex. Any bounded zone-name class — an IANA-shaped one, or even raw
  # `[^)\n]{1,40}` — makes the trailing group optional in practice: a rendering
  # it cannot span (`(UTC-04:00)`, a non-ASCII dash, an unclosed or overlong
  # parenthetical) fails the group, leaves `zone` empty, and silently takes the
  # "no zone named, assume host-local" path — applying *this* host's offset to a
  # wall clock that may have been written somewhere else, in either direction.
  # So the regex captures the whole remainder of the line as `tail` and
  # `zone_from_tail/1` decides: empty tail means no zone was named (host-local),
  # a closed `(...)` yields whatever is between the parens for
  # `host_zone_matches?/1` to accept or reject, and anything else declines the
  # parse outright.
  @quota_reset_wallclock_signature ~r/
      ^[ \t]*you.{0,3}ve[ ]hit[ ]your[ ](?:session|usage)[ ]limit
      [^\n]*?
      \bresets[ \t]+(?<hour>\d{1,2})(?::(?<minute>\d{2}))?[ \t]*(?<meridiem>am|pm)
      (?<tail>[^\n]*)
  /mix

  @credit_signature ~r/
      insufficient[^\n]{0,20}(credit|balance|funds|quota)
    | credit[ _]balance[^\n]{0,20}(too[ _]low|low)
    | out[ _]of[^\n]{0,20}(credit|token|quota)
    | (quota|billing)[^\n]{0,20}(exceeded|exhausted|required)
    | payment[ _]required
    | \b402\b
    | upgrade[^\n]{0,20}plan
  /ix

  # bd-6nr53z: tightened to require a *positive* signal — a status code, an
  # explicit provider error token, or "overloaded"/"rate limit" in close
  # proximity to "api" — rather than the bare words "rate-limit"/"overloaded"
  # anywhere in the tail. The bare-word form false-matched a worker's own
  # tool output (e.g. grepping source that mentions "rate-limit" identifiers
  # in comments/code, as in run c88c77b0) with no genuine API error at all.
  @rate_limit_signature ~r/
      \b429\b
    | \b529\b
    | overloaded_error
    | rate_limit_error
    | too[ _]many[ _]requests
    | resource_exhausted
    | api[^\n]{0,20}overload
    | overload[^\n]{0,20}api
    | http[ _]?5(0|2|3)\d\b[^\n]{0,30}(overload|rate[ _-]?limit)
  /ix

  # Matches the local Anthropic proxy's 502/503 error body and common upstream
  # connectivity failures. Ordered AFTER rate-limit so an "overloaded" 503 from
  # Anthropic itself is captured as rate-limited (the right remediation), while
  # a proxy-side "upstream unreachable" 502 is captured here.
  @gateway_error_signature ~r/
      proxy_error
    | upstream[ _]unreachable
    | \b502\b
    | bad[ _]gateway
    | \b503\b[^\n]{0,40}(service[ _]unavailable|temporarily)
    | upstream[^\n]{0,40}(timeout|unreachable|refused)
    | connection[^\n]{0,40}(refused|reset|timeout)
    | receive[ _]timeout
  /ix

  # bd-80kdgy: the marker an agent stream parser emits when it meets an event
  # vocabulary it doesn't know (see `Arbiter.Agents.Codex.Stream`). Its presence
  # means the transcript is incomplete by construction, so whatever the exit
  # status says about the run is not trustworthy.
  @schema_drift_signature ~r/unrecognized[ _]stream[ _]event/i

  # bd-8cn795: the Claude CLI's own autocompact-loop detector. Fires when the
  # context refills to the limit within a few turns of the previous compact,
  # several times in a row — a deterministic function of the task's working
  # set (whole-file reads of large modules), not a transient blip. Matched
  # loosely on "autocompact" + "thrash" rather than the exact N/N wording so a
  # future CLI phrasing tweak doesn't silently fall through to :crashed.
  @context_thrash_signature ~r/autocompact[^\n]{0,20}thrash/i

  # bd-606zlr: the harness's OWN markers for "an asynchronous wait is now
  # armed". Every one of them is text this Arbiter build did not write and the
  # agent did not choose the wording of — they are emitted by the CLI tool
  # harness when a `Bash` call is backgrounded (either up front or after
  # blowing its tool timeout), when a `Monitor` starts, or when a
  # `ScheduleWakeup` is booked. Matching the harness's phrasing rather than the
  # agent's prose ("I'll wait for the notification") is deliberate: the prose
  # is unbounded paraphrase, the markers are fixed strings.
  @async_arm_signature ~r/
      you[ _]will[ _]be[ _]notified
    | moved[ _]to[ _]the[ _]background[ _]\(id:
    | running[ _]in[ _]the[ _]background[ _]with[ _]id:
    | command[ _]running[ _]in[ _]background[ _]with[ _]id:
    | monitor[ _]started[ _]\(task
    | wakeup[ _]scheduled
  /ix

  # The counterpart: evidence the agent actually *drained* what it armed, in
  # the same session, before the run ended. A blocking `TaskOutput` /
  # `BashOutput` read (or a `TaskStop`) after the arm marker means the wait was
  # honoured synchronously and the run ended for some other reason — the
  # correct pattern, not this bug.
  @async_drain_signature ~r/\b(TaskOutput|BashOutput|TaskStop)\(/i

  # How many lines back from the END of the run to look for an un-drained arm.
  # Deliberately much tighter than @tail_lines (80): a background task armed
  # mid-run and properly drained is separated from the run's end by the drain
  # call plus its output, so a narrow terminal window is what distinguishes
  # "armed and abandoned" from "armed and handled".
  @async_arm_window 12

  @doc """
  Classify a stop from the subprocess exit status and captured output.

  `exit_status` is the integer the Erlang port reported, or `nil` when the
  subprocess is still alive (a no-output stall detected by the watchdog).

  `output_lines` is the captured stdout/stderr, **newest-first or oldest-first**
  — order does not matter, we only scan the tail for signatures. Pass the
  worker's `meta[:output_lines]` (oldest-first) directly.

  Returns a `%StopReason{}`.
  """
  @spec classify(integer() | nil, [String.t()]) :: t()
  # Pre-existing complexity 18 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def classify(exit_status, output_lines) when is_list(output_lines) do
    haystack = signature_haystack(output_lines)
    signal = signal_for(exit_status)

    cond do
      # bd-6nr53z: checked FIRST, ahead of every provider-error signature. The
      # autocompact-thrash message is the CLI's own deterministic loop
      # detector and the run's genuine terminal signal — it must win even
      # when the same tail window also contains incidental "rate-limit" /
      # "overloaded" -shaped words from a tool result the worker merely read
      # (source comments, grep output, the task's own prose). Those weaker
      # signatures are matched by substring anywhere in the haystack with no
      # positional awareness, so ordering is the only thing that lets the
      # true signal outrank them (see run c88c77b0-2927-41ec-b582-6210538a43b3).
      Regex.match?(@context_thrash_signature, haystack) ->
        %__MODULE__{
          category: :context_thrash,
          summary:
            "agent's context window thrashed (autocompact refilled immediately, several " <>
              "cycles in a row) before completing any work — the task's working set is too " <>
              "large for this model's context window",
          remediation:
            "Deterministic for this task's file set — retrying identically will fail the " <>
              "same way. Re-dispatch on a 1M-context model (e.g. claude-sonnet-5[1m]), or " <>
              "narrow reads with grep + bounded offset/limit ranges instead of whole-file reads.",
          exit_status: exit_status,
          signal: signal
        }

      Regex.match?(@quota_signature, haystack) ->
        retry_after = retry_after_from(haystack)

        %__MODULE__{
          category: :quota_exhausted,
          summary: "agent's 5h plan usage limit was reached (not a billing/credit failure)",
          remediation: quota_remediation(retry_after),
          exit_status: exit_status,
          signal: signal,
          retry_after: retry_after
        }

      Regex.match?(@auth_signature, haystack) ->
        %__MODULE__{
          category: :auth_expired,
          summary: "agent could not authenticate (credentials expired or invalid)",
          remediation:
            "Re-authenticate the agent CLI (Claude: refresh ~/.claude/.credentials.json " <>
              "via `claude` login; Gemini: refresh GEMINI_API_KEY / re-run `gemini` auth), " <>
              "then re-dispatch.",
          exit_status: exit_status,
          signal: signal
        }

      Regex.match?(@credit_signature, haystack) ->
        %__MODULE__{
          category: :credit_exhausted,
          summary: "agent ran out of credits / quota",
          remediation:
            "Top up the provider account or rotate to a funded API key, then re-dispatch.",
          exit_status: exit_status,
          signal: signal
        }

      Regex.match?(@rate_limit_signature, haystack) ->
        %__MODULE__{
          category: :rate_limited,
          summary: "agent was rate-limited / the API was overloaded",
          remediation: "Usually transient — retry with backoff, or reduce concurrent workers.",
          exit_status: exit_status,
          signal: signal
        }

      Regex.match?(@gateway_error_signature, haystack) ->
        %__MODULE__{
          category: :gateway_error,
          summary: "agent lost connectivity to the API (transient gateway / proxy error)",
          remediation:
            "Transient network blip between the harness proxy and Anthropic. " <>
              "Auto-resuming the session — if retries are exhausted, check proxy logs.",
          exit_status: exit_status,
          signal: signal
        }

      # Ordered after the provider-error signatures (a real 401/429 still reads
      # off raw stderr and is the better diagnosis) but ahead of :stalled and
      # :exited_without_done. Both of those would otherwise mis-explain drift:
      # an unparsed stream renders no output, so the no-output watchdog trips,
      # and the run exits 0 having "never signalled done" — and both remediations
      # say "re-dispatch", which reproduces the failure exactly.
      Regex.match?(@schema_drift_signature, haystack) ->
        %__MODULE__{
          category: :stream_schema_drift,
          summary:
            "the agent CLI emitted a --json event schema this Arbiter build does not " <>
              "understand — the transcript, token usage, and `arb done` detection for this " <>
              "run are all incomplete, so a clean exit here means nothing",
          remediation:
            "This is a harness bug, not a task failure — re-dispatching will fail " <>
              "identically. Pin the agent CLI to a known-good version or update the " <>
              "provider's stream parser (Arbiter.Agents.*.Stream) to the new vocabulary.",
          exit_status: exit_status,
          signal: signal
        }

      is_nil(exit_status) ->
        %__MODULE__{
          category: :stalled,
          summary: "agent produced no output within the watchdog window (possible hang)",
          remediation:
            "Inspect the worker's transcript; if genuinely hung, stop and re-dispatch the task.",
          exit_status: nil,
          signal: nil
        }

      is_integer(signal) ->
        %__MODULE__{
          category: :killed,
          summary: "agent subprocess was killed by signal #{signal}",
          remediation:
            "External kill, OOM, or host restart. Check dmesg/host health, then re-dispatch.",
          exit_status: exit_status,
          signal: signal
        }

      exit_status == 7 and blank_output?(output_lines) ->
        %__MODULE__{
          category: :spawn_exec_failed,
          summary:
            "agent subprocess never started — exec() failed with E2BIG (exit 7): an argv " <>
              "element exceeded Linux's 131 072-byte MAX_ARG_STRLEN limit, almost certainly " <>
              "the prompt spliced directly into argv",
          remediation:
            "This is a harness bug, not a task failure — the prompt-building path must " <>
              "deliver oversized prompts via stdin/temp file instead of argv. Re-dispatching " <>
              "without a harness fix will crash identically every time.",
          exit_status: exit_status,
          signal: nil
        }

      exit_status not in [0, nil] and blank_output?(output_lines) ->
        %__MODULE__{
          category: :spawn_exec_failed,
          summary:
            "agent subprocess exited (code #{exit_status}) with zero captured output — the " <>
              "process likely never ran (exec failure before the child started)",
          remediation:
            "Check for a bad CLI flag, missing/non-executable binary, or an oversized argv " <>
              "element (MAX_ARG_STRLEN). Not a normal task crash — investigate the spawn path.",
          exit_status: exit_status,
          signal: nil
        }

      # bd-606zlr. Ordered AFTER every provider-error signature (a genuine
      # 401/429 in the same tail is the better diagnosis) but ahead of the
      # plain clean-exit clause it refines. Scoped to `exit_status == 0`
      # because a crash that happens to have backgrounded something earlier is
      # a crash — the exit status stays authoritative.
      exit_status == 0 and abandoned_async_wait?(output_lines) ->
        %__MODULE__{
          category: :async_wait_abandoned,
          summary:
            "agent armed an asynchronous wait (Monitor / ScheduleWakeup / backgrounded " <>
              "command) and yielded the turn to await the notification — but a " <>
              "non-interactive `--print` session ends on the first turn with no tool " <>
              "call, so that notification could never be delivered",
          remediation:
            "Not a task failure and not the agent's judgement — the command genuinely " <>
              "exceeded the tool-call timeout. The worktree usually still holds real, " <>
              "uncommitted work, so resume the session in place with corrective guidance " <>
              "(drain background tasks with a blocking `TaskOutput` in the SAME turn; " <>
              "never wait on `Monitor`/`ScheduleWakeup`) rather than discarding it.",
          exit_status: 0,
          signal: nil
        }

      exit_status == 0 ->
        %__MODULE__{
          category: :exited_without_done,
          summary: "agent exited cleanly but never signalled `arb done` (quit before completing)",
          remediation:
            "The worker stopped early without finishing the task. Review the transcript, " <>
              "then re-dispatch.",
          exit_status: 0,
          signal: nil
        }

      true ->
        %__MODULE__{
          category: :crashed,
          summary: "agent subprocess crashed (exit code #{exit_status})",
          remediation:
            "Non-zero exit with no recognized cause — often a bad CLI flag or an immediate " <>
              "subprocess error. Check the captured stderr/exit code, then re-dispatch.",
          exit_status: exit_status,
          signal: signal
        }
    end
  end

  @doc """
  Build a `:spawn_failed` reason (bd-bi5pn0): a `Dispatch.dispatch/2` step
  after `start_worker/3` failed, before any agent subprocess ever ran. Unlike
  `classify/2` this isn't derived from an exit status — there is no
  process/port to inspect — so the dispatch error term itself is folded into
  the summary.
  """
  @spec spawn_failed(term()) :: t()
  def spawn_failed(dispatch_error) do
    %__MODULE__{
      category: :spawn_failed,
      summary: "worker spawn failed after registration: #{inspect(dispatch_error)}",
      remediation:
        "A dispatch step failed after the worker was registered (often a transient " <>
          "network/VPN outage). Investigate the error above, then re-dispatch the task.",
      exit_status: nil,
      signal: nil
    }
  end

  @doc """
  A compact one-line label for logs / message subjects, e.g.
  `"credentials expired (exit 1)"`.
  """
  @spec label(t()) :: String.t()
  # Pre-existing complexity 18 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def label(%__MODULE__{category: category} = reason) do
    base =
      case category do
        :auth_expired -> "credentials expired"
        :quota_exhausted -> "5h usage limit reached"
        :credit_exhausted -> "credits exhausted"
        :rate_limited -> "rate-limited"
        :gateway_error -> "gateway error (proxy/upstream)"
        :context_thrash -> "context window thrashed (autocompact loop)"
        :killed -> "killed by signal #{reason.signal}"
        :spawn_exec_failed -> "spawn failed (no output — exec error)"
        :crashed -> "crashed"
        :stream_schema_drift -> "agent CLI stream schema not understood (harness bug)"
        :exited_without_done -> "exited without completing"
        :async_wait_abandoned -> "abandoned an async wait (background task never drained)"
        :stalled -> "stalled (no output)"
        :missing_worktree -> "no worktree provisioned (nothing to integrate)"
        :spawn_failed -> "spawn failed (dispatch error after worker registration)"
      end

    case reason.exit_status do
      nil -> base
      code -> "#{base} (exit #{code})"
    end
  end

  @doc """
  Serialize to a plain map for stashing in worker `meta` / persisting in a
  message body. Keeps the struct out of any place that must survive a term
  round-trip (PubSub, Ash JSON columns).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = reason) do
    %{
      category: reason.category,
      summary: reason.summary,
      remediation: reason.remediation,
      exit_status: reason.exit_status,
      signal: reason.signal,
      retry_after: reason.retry_after
    }
  end

  # ---- internals ---------------------------------------------------------

  # The agent runs under `sh -c 'exec "$@"'`, so a child terminated by signal N
  # surfaces as exit status `128 + N` (POSIX shell convention). Map that band
  # back to the signal number so the escalation can name it. Codes outside the
  # band are ordinary exit codes (no signal).
  defp signal_for(status) when is_integer(status) and status > 128 and status < 160,
    do: status - 128

  defp signal_for(_), do: nil

  # Scan only the tail — the error/auth message a CLI prints on a failed spawn
  # is among the last lines, and bounding the scan keeps a chatty 1000-line
  # buffer from making the regex pass expensive.
  @tail_lines 80

  defp signature_haystack(output_lines) do
    output_lines
    |> Enum.take(-@tail_lines)
    |> Enum.join("\n")
  end

  # bd-11abk2: an exec() failure (bad argv, E2BIG, missing binary) happens
  # before the child process runs, so it can produce no stdout/stderr at
  # all — not even a blank line. Genuine crashes almost always leave *some*
  # trace. `output_lines` may contain empty-string entries from the port's
  # line-buffering, so trim before checking for emptiness.
  defp blank_output?(output_lines) do
    Enum.all?(output_lines, fn line -> is_binary(line) and String.trim(line) == "" end)
  end

  # bd-606zlr: did the run end with an asynchronous wait armed and never
  # drained? `output_lines` is oldest-first (every caller reverses its
  # newest-first accumulator before calling in), so the terminal window is the
  # LAST @async_arm_window entries.
  #
  # "Abandoned" means: an arm marker appears in that window, and nothing after
  # it drains the thing it armed. The drain check is what keeps the correct
  # pattern — background a command, then block on `TaskOutput` in the same
  # turn — from being misread as this failure.
  defp abandoned_async_wait?(output_lines) do
    window = Enum.take(output_lines, -@async_arm_window)

    case last_index_matching(window, @async_arm_signature) do
      nil ->
        false

      idx ->
        window
        |> Enum.drop(idx + 1)
        |> Enum.any?(&Regex.match?(@async_drain_signature, &1))
        |> Kernel.not()
    end
  end

  defp last_index_matching(lines, regex) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {line, idx}, acc ->
      if is_binary(line) and Regex.match?(regex, line), do: idx, else: acc
    end)
  end

  # Opportunistically pull the unix-epoch-seconds reset time the Claude CLI
  # appends to its usage-limit message ("...reached|1735689600"). Returns nil
  # when the message doesn't carry one (older CLI versions, or a paraphrase
  # like "5-hour limit reached, try again later") — the caller falls back to a
  # generic "wait for the window to reset" remediation.
  # The `|<epoch>` form is unambiguous, so it wins when both are present; the
  # wall-clock form (bd-cfhj7z) is the fallback.
  defp retry_after_from(haystack) do
    epoch_reset_from(haystack) || wallclock_reset_from(haystack)
  end

  defp epoch_reset_from(haystack) do
    with [_, secs] <- Regex.run(@quota_reset_signature, haystack),
         {secs, _} <- Integer.parse(secs),
         {:ok, dt} <- DateTime.from_unix(secs) do
      dt
    else
      _ -> nil
    end
  end

  # bd-cfhj7z: no tz database is bundled (the umbrella has neither :tzdata nor
  # :tz, and Elixir's default `Calendar.UTCOnlyTimeZoneDatabase` cannot resolve
  # "America/New_York"). We do not need one: the CLI renders that wall clock in
  # *its own host's* local zone, and its host is this host — so the offset we
  # need is the one the BEAM already gets from the OS's zoneinfo via
  # `NaiveDateTime.local_now/0`.
  #
  # That equivalence is asserted, not assumed: when the message names a zone we
  # only use the local offset if that name matches the host's configured zone
  # (TZ, then the /etc/localtime symlink, then /etc/timezone). A mismatch — or
  # a host whose zone we cannot name — yields nil, which is the pre-existing
  # "no reset time reported" path, not a wrong one.
  #
  # Known bound: if a DST transition falls between now and the reset, the
  # current offset is off by up to an hour. That is a ≤1h error twice a year
  # against a 5h blanket default, and `quota_resume_backoff_ms/1` clamps the
  # result to a 60s floor, so the failure mode is one early retry, not a hang.
  #
  # Review round 1, finding 1: `classify/2` runs at *session exit*, not when the
  # CLI printed the phrase, and the two can be far apart (`claude session error
  # 674.5s` in the very run this ticket cites). If the reset instant falls
  # inside that gap, a naive "always the next occurrence" roll turns a window
  # that has ALREADY reset into a ~24h park -- strictly worse than the 5h
  # default it replaces. Two bounds prevent that, both resting on the fact that
  # this wording only ever describes the 5h window (a 7-day reset carries a
  # date, which `@quota_reset_wallclock_signature` cannot match):
  #
  #   * `@wallclock_past_slack_seconds` -- a candidate less than an hour behind
  #     the local clock is the reset we just missed, not tomorrow's. It is
  #     returned in the past, so `Arbiter.Worker.quota_resume_backoff_ms/1`
  #     takes its 60s floor and the worker retries promptly. A wasted retry
  #     costs one re-detect; a wrong day costs a day.
  #   * `@wallclock_max_horizon_seconds` -- any reset that survives the roll but
  #     lands further out than the window itself means the date guess was wrong,
  #     so we decline entirely and the pre-existing 5h default stands. That
  #     makes the wall-clock path never worse than the behaviour before this
  #     branch, in either direction.
  @wallclock_past_slack_seconds 3_600
  @wallclock_max_horizon_seconds 6 * 3_600

  defp wallclock_reset_from(haystack) do
    with {hour, minute, zone} <- parse_wallclock(haystack),
         true <- host_zone_matches?(zone),
         reset =
           wallclock_reset_utc(
             NaiveDateTime.local_now(),
             local_utc_offset_seconds(),
             hour,
             minute
           ),
         true <- DateTime.diff(reset, DateTime.utc_now()) <= @wallclock_max_horizon_seconds do
      reset
    else
      _ -> nil
    end
  end

  @doc false
  @spec parse_wallclock(String.t()) :: {0..23, 0..59, String.t() | nil} | nil
  def parse_wallclock(haystack) when is_binary(haystack) do
    with %{"hour" => raw_hour, "meridiem" => meridiem} = caps <-
           Regex.named_captures(@quota_reset_wallclock_signature, haystack),
         {hour12, ""} when hour12 in 0..12 <- Integer.parse(raw_hour),
         minute when minute in 0..59 <- parse_minute(caps["minute"]),
         {:ok, zone} <- zone_from_tail(caps["tail"]) do
      {to_24h(hour12, String.downcase(meridiem)), minute, zone}
    else
      _ -> nil
    end
  end

  @wallclock_zone_tail ~r/^[ \t]*\((?<zone>[^)\n]*)\)/

  # See the capture note on `@quota_reset_wallclock_signature`. `{:ok, nil}` is
  # "no zone was named"; `{:ok, zone}` hands a raw string to
  # `host_zone_matches?/1`, which rejects anything that is not this host's zone
  # name (so `(UTC-04:00)` and `()` alike decline); `:error` is text we cannot
  # account for, which must not be read as an absent zone.
  defp zone_from_tail(tail) do
    cond do
      String.trim(tail) == "" ->
        {:ok, nil}

      caps = Regex.named_captures(@wallclock_zone_tail, tail) ->
        {:ok, caps["zone"]}

      true ->
        :error
    end
  end

  defp parse_minute(minute) when minute in [nil, ""], do: 0
  defp parse_minute(minute), do: String.to_integer(minute)

  defp to_24h(12, "am"), do: 0
  defp to_24h(12, "pm"), do: 12
  defp to_24h(hour, "pm"), do: hour + 12
  defp to_24h(hour, _am), do: hour

  # `3:30am` names a wall-clock time, not a date. The CLI only prints a reset
  # that had not happened yet *when it printed*, so a time well past locally
  # belongs to tomorrow -- but only well past: within
  # `@wallclock_past_slack_seconds` the reset is the one that elapsed between
  # the phrase and this exit, and is returned in the past so the caller retries
  # on its 60s floor. An exact tie is likewise "now", not a full day out.
  @doc false
  @spec wallclock_reset_utc(NaiveDateTime.t(), integer(), 0..23, 0..59) :: DateTime.t()
  def wallclock_reset_utc(%NaiveDateTime{} = local_now, offset_seconds, hour, minute)
      when is_integer(offset_seconds) do
    candidate = NaiveDateTime.new!(NaiveDateTime.to_date(local_now), Time.new!(hour, minute, 0))

    candidate =
      if NaiveDateTime.diff(local_now, candidate, :second) > @wallclock_past_slack_seconds do
        NaiveDateTime.add(candidate, 86_400, :second)
      else
        candidate
      end

    candidate
    |> NaiveDateTime.add(-offset_seconds, :second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  # Whole-minute rounding: the two clock reads are microseconds apart, and every
  # modern IANA offset is a whole number of minutes.
  defp local_utc_offset_seconds do
    diff = NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now(), :second)
    round(diff / 60) * 60
  end

  @doc false
  @spec host_time_zone_name() :: String.t() | nil
  def host_time_zone_name do
    case presence(System.get_env("TZ")) do
      nil -> host_zone_from_files()
      tz -> tz |> String.trim_leading(":") |> zone_from_path()
    end
  end

  defp host_zone_from_files do
    case File.read_link("/etc/localtime") do
      {:ok, target} ->
        zone_from_path(target)

      _ ->
        case File.read("/etc/timezone") do
          {:ok, contents} -> contents |> String.trim() |> presence()
          _ -> nil
        end
    end
  end

  defp zone_from_path(path) do
    case String.split(path, "zoneinfo/", parts: 2) do
      [_, zone] -> presence(zone)
      _ -> presence(path)
    end
  end

  # A message whose reset clause names no zone at all is taken at face value: the
  # CLI wrote it in host-local time and we only need the offset, not the name.
  # `zone_from_tail/1` guarantees this clause is reached only for a genuinely
  # empty tail — every parenthetical, parseable or not, reaches the comparison
  # below and must match the host's own zone name to be trusted.
  defp host_zone_matches?(nil), do: true

  defp host_zone_matches?(zone) do
    case host_time_zone_name() do
      nil -> false
      host -> String.downcase(host) == String.downcase(zone)
    end
  end

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  defp quota_remediation(%DateTime{} = retry_after) do
    "Provider-side plan usage limit, not a billing failure — no action needed. " <>
      "The window resets at #{DateTime.to_iso8601(retry_after)}; auto-resuming after that."
  end

  defp quota_remediation(nil) do
    "Provider-side plan usage limit, not a billing failure — no action needed. " <>
      "Wait for the 5h window to reset (no reset time was reported), then re-dispatch."
  end
end
