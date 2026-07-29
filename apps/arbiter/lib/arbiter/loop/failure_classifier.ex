defmodule Arbiter.Loop.FailureClassifier do
  @moduledoc """
  Segment a failed `worker_runs` row into an analysis class — the critical
  first step of the Stage 1 loop-analysis pass (bd-dyfaq3, epic #1011).

  A naive pass pointed at `status = failed` spends its whole budget learning
  about our own deploy restarts: `server restarted` is the modal failure by a
  wide margin. So failures are segmented by an **allowlist, not a heuristic**,
  into:

    * `:operational`  — server restarts, rate-limits, auth failures, merge/CI
      infra, review-timeouts. Route to ops; **never** to prompt changes.
    * `:agent_quality` — `:review_gate_rejected`, "never signalled `arb done`",
      `:uncommitted_at_completion`, `:no_commits_at_completion`,
      `:secret_in_commit`, and **context exhaustion**. These are the only
      failures a prompt/skill change can move.
    * `:excluded`      — corpus noise (`:simulated_failure`) that must not
      pollute any denominator.
    * `:unknown`       — a reason nobody allowlisted. Surfaced, **never**
      silently bucketed as operational.

  ## `failure_reason` is a hint, not ground truth

  The label lies. The proof is this task's own first attempt — run
  `c88c77b0-2927-41ec-b582-6210538a43b3` was recorded
  `failure_reason: "agent was rate-limited / the API was overloaded"`, but its
  transcript contains no 429, no overload, no quota error — only an autocompact
  thrash and a bare `claude session error`. The true cause was **context
  exhaustion**: an agent with no read discipline burning its own window. Taken
  at face value the label files it *operational → drop it*, hiding the purest
  agent-quality signal in the corpus behind ops noise.

  So `classify/2` takes the transcript's terminal lines and **corroborates**:

    * Context exhaustion is detected from the transcript
      (`context_exhaustion?/1`) — an autocompact-thrash message, or a
      `claude session error` with no genuine API error — **regardless of the
      label**, and reclassifies an operational label to
      `:agent_quality`/`:context_exhaustion`.
    * A *genuine* API error payload (`api_error_signal?/1`) — not the word
      "rate" or "quota" appearing in source the worker was merely reading —
      corroborates an operational rate-limit label and is left operational.

  Every result carries `label_class` (what the label alone said),
  `reclassified?`, `corroborated?`, and `corroboration`
  (`:agree | :disagree | :unavailable`) so the pass can report the
  label-vs-transcript **disagreement rate** as a first-class corpus-integrity
  finding rather than silently correcting it.
  """

  @type class :: :operational | :agent_quality | :excluded | :unknown
  @type result :: %{
          class: class(),
          subcategory: atom(),
          label_class: class(),
          reclassified: boolean(),
          corroborated: boolean(),
          corroboration: :agree | :disagree | :unavailable
        }

  # Operational allowlist: {matcher, subcategory}. A matcher is a substring
  # (case-insensitive) or a regex. Order matters — first match wins.
  @operational [
    {"server restarted", :server_restart},
    {"rate-limited", :rate_limited},
    {"api was overloaded", :rate_limited},
    {"could not authenticate", :auth_failure},
    {"credentials exp", :auth_failure},
    {":awaiting_review_timeout", :review_timeout},
    {":merge_failed", :merge_failed},
    {":mr_closed", :merge_failed},
    {"merge_failed", :merge_failed}
  ]

  # Agent-quality allowlist.
  @agent_quality [
    {":review_gate_rejected", :review_gate_rejected},
    {"never signalled", :never_signalled_done},
    {"never signaled", :never_signalled_done},
    {":uncommitted_at_completion", :uncommitted_at_completion},
    {":no_commits_at_completion", :no_commits_at_completion},
    {":secret_in_commit", :secret_in_commit},
    {"context window thrashed", :context_exhaustion},
    {"autocompact", :context_exhaustion}
  ]

  # Reasons excluded from the corpus entirely.
  @excluded [
    {":simulated_failure", :simulated_failure}
  ]

  @doc """
  Classify a failed run from its `failure_reason` and the transcript's terminal
  lines (a list of strings — pass `[]` when no transcript is available).
  """
  @spec classify(String.t() | nil, [String.t()]) :: result()
  def classify(failure_reason, transcript_lines) when is_list(transcript_lines) do
    {label_class, label_sub} = label_of(failure_reason)

    context? = context_exhaustion?(transcript_lines)
    api_error? = api_error_signal?(transcript_lines)
    have_transcript? = transcript_lines != []

    cond do
      # Transcript wins: a context-exhaustion thrash with no genuine API error
      # is agent-quality no matter what the label claimed.
      context? and not api_error? ->
        final(:agent_quality, :context_exhaustion, label_class, have_transcript?)

      true ->
        # No transcript override — trust the allowlist label.
        final(label_class, label_sub, label_class, have_transcript?)
    end
  end

  @doc """
  True when the transcript's terminal lines show a context-exhaustion death —
  the autocompact-thrash fingerprint (`Autocompact is thrashing …` or an
  explicit "context window thrashed"). Independent of `failure_reason`.

  A bare `claude session error` line is deliberately **not** a trigger: on the
  real corpus it accompanies nearly every failed session regardless of cause
  (server restart, auth failure, crash), so keying on it reclassifies
  operational deaths as agent-quality. The autocompact message is the only
  unambiguous context-death signal — and it is exactly what run `c88c77b0`
  carries under its misleading "rate-limited" label.
  """
  @spec context_exhaustion?([String.t()]) :: boolean()
  def context_exhaustion?(transcript_lines) do
    Enum.any?(transcript_lines, fn line ->
      l = String.downcase(line)

      String.contains?(l, "autocompact is thrashing") or
        String.contains?(l, "context window thrashed")
    end)
  end

  @doc """
  True when a line looks like a *genuine* API error payload (overload / rate
  limit / quota / 4xx-5xx), as opposed to the words "rate"/"quota" appearing in
  source code or prose the worker was reading. This is the exact distinction
  that mislabelled c88c77b0.
  """
  @spec api_error_signal?([String.t()]) :: boolean()
  def api_error_signal?(transcript_lines) do
    Enum.any?(transcript_lines, fn line ->
      l = String.downcase(line)

      String.contains?(l, "overloaded_error") or
        String.contains?(l, "rate_limit_error") or
        String.contains?(l, "insufficient_quota") or
        (String.contains?(l, "api error") and
           (String.contains?(l, "429") or String.contains?(l, "529") or
              String.contains?(l, "overload")))
    end)
  end

  # --- internals ---------------------------------------------------------

  defp final(final_class, subcategory, label_class, have_transcript?) do
    reclassified = final_class != label_class

    corroboration =
      cond do
        not have_transcript? -> :unavailable
        reclassified -> :disagree
        true -> :agree
      end

    %{
      class: final_class,
      subcategory: subcategory,
      label_class: label_class,
      reclassified: reclassified,
      corroborated: have_transcript?,
      corroboration: corroboration
    }
  end

  # Classify by the allowlist on the label alone.
  defp label_of(nil), do: {:unknown, :unclassified}

  defp label_of(reason) when is_binary(reason) do
    down = String.downcase(reason)

    find(@excluded, down) ||
      find(@operational, down) ||
      find(@agent_quality, down) ||
      {:unknown, :unclassified}
  end

  defp find(table, down) do
    Enum.find_value(table, fn {matcher, sub} ->
      if matches?(matcher, down), do: {class_for(table), sub}
    end)
  end

  defp class_for(@excluded), do: :excluded
  defp class_for(@operational), do: :operational
  defp class_for(@agent_quality), do: :agent_quality

  defp matches?(%Regex{} = re, down), do: Regex.match?(re, down)
  defp matches?(substr, down) when is_binary(substr), do: String.contains?(down, substr)
end
