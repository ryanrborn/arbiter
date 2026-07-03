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
  Admiral escalation carries the right remediation.

  ## Categories

    * `:auth_expired` — the agent CLI could not authenticate (401 / "invalid
      authentication credentials" / OAuth expiry). Remediation: re-authenticate.
      Distinct from a generic failure because the fix is operator credentials,
      not the task. Provider-agnostic (Claude OAuth, Gemini API key).
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
    * `:stalled` — no exit at all; the subprocess is alive but produced no
      output within the watchdog window (caller passes `exit_status: nil`).
    * `:missing_worktree` — the worker signalled `arb done` on a reviewable
      code directive but no per-task branch/worktree was ever provisioned, so
      there is nothing to integrate (bd-7pe74i). Not a subprocess-exit
      classification — synthesized by the completion path to refuse closing a
      bead that produced no deliverable. Remediation: investigate why
      provisioning was skipped, then re-dispatch.

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
          | :credit_exhausted
          | :rate_limited
          | :gateway_error
          | :killed
          | :spawn_exec_failed
          | :crashed
          | :exited_without_done
          | :stalled
          | :missing_worktree

  @type t :: %__MODULE__{
          category: category(),
          summary: String.t(),
          remediation: String.t() | nil,
          exit_status: integer() | nil,
          signal: integer() | nil
        }

  @enforce_keys [:category, :summary]
  defstruct [:category, :summary, :remediation, :exit_status, :signal]

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

  @credit_signature ~r/
      insufficient[^\n]{0,20}(credit|balance|funds|quota)
    | credit[ _]balance[^\n]{0,20}(too[ _]low|low)
    | out[ _]of[^\n]{0,20}(credit|token|quota)
    | (quota|billing)[^\n]{0,20}(exceeded|exhausted|required)
    | payment[ _]required
    | \b402\b
    | upgrade[^\n]{0,20}plan
  /ix

  @rate_limit_signature ~r/
      \b429\b
    | rate[ _-]?limit
    | too[ _]many[ _]requests
    | overloaded
    | resource[ _]exhausted
    | retry[^\n]{0,20}after
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
  def classify(exit_status, output_lines) when is_list(output_lines) do
    haystack = signature_haystack(output_lines)
    signal = signal_for(exit_status)

    cond do
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
  A compact one-line label for logs / message subjects, e.g.
  `"credentials expired (exit 1)"`.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{category: category} = reason) do
    base =
      case category do
        :auth_expired -> "credentials expired"
        :credit_exhausted -> "credits exhausted"
        :rate_limited -> "rate-limited"
        :gateway_error -> "gateway error (proxy/upstream)"
        :killed -> "killed by signal #{reason.signal}"
        :spawn_exec_failed -> "spawn failed (no output — exec error)"
        :crashed -> "crashed"
        :exited_without_done -> "exited without completing"
        :stalled -> "stalled (no output)"
        :missing_worktree -> "no worktree provisioned (nothing to integrate)"
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
      signal: reason.signal
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
end
