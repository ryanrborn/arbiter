defmodule Arbiter.Loop.FailureClassifier do
  @moduledoc """
  Segment a failed `worker_runs` row into an analysis class — the critical
  first step of the Stage 1 loop-analysis pass (bd-dyfaq3, epic #1011).

  A naive pass pointed at `status = failed` spends its whole budget learning
  about our own deploy restarts: `server restarted` is the modal failure by a
  wide margin. So failures are segmented by an **allowlist, not a heuristic**,
  into:

    * `:operational`  — server restarts, rate-limits, auth failures, merge/CI
      infra, review-timeouts, and **spawn failures** (`worker spawn failed
      after registration: ...`, and the `:inspect_worktree_failed` /
      `:fetch_failed` / `:worktree_failed` tags it wraps — #1220). A spawn
      failure happens after worker registration but before any agent starts:
      no prompt, no model call, no transcript, so it carries zero
      agent-quality signal by construction and must never fall through to
      `:unclassified`. Route to ops; **never** to prompt changes.
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

  ## Structured evidence beats a tail regex (bd-apwfmy)

  `context_exhaustion?/1` and friends are *re-derivations*.
  `Arbiter.Worker.StopReason` already classified the death **typed**, at the
  moment it happened, with the whole captured output in hand — and Arbiter
  then kept only the English sentence it renders (`reason.summary` becomes
  `failure_reason`). Persisting the typed `category` alongside it
  (`worker_runs.stop_category`) turns the corroboration into a lookup instead
  of a scan.

  So `classify/3` takes an optional `:stop_category` and, when it is one of the
  **unambiguous** categories in `@stop_category_map`, uses it directly and
  reports `evidence: :stop_category` — no transcript needed. Categories that
  genuinely carry no verdict (`:crashed`, `:stalled` — "non-zero exit, no
  recognized signature") deliberately fall through to the transcript/label
  path rather than manufacturing false precision.

  `evidence` names which path produced the verdict (`:stop_category` /
  `:transcript` / `:label`), so the pass can report how much of a window it
  still had to text-mine. `corroborated` means "evidence beyond the label was
  available" — now true for a structured verdict with no transcript at all, so
  the disagreement rate keeps its denominator while the transcript reads go
  away.
  """

  @type class :: :operational | :agent_quality | :excluded | :unknown
  @type evidence :: :stop_category | :transcript | :label
  @type result :: %{
          class: class(),
          subcategory: atom(),
          label_class: class(),
          reclassified: boolean(),
          corroborated: boolean(),
          corroboration: :agree | :disagree | :unavailable,
          evidence: evidence()
        }

  # Operational allowlist: {matcher, subcategory}. A matcher is a substring
  # (case-insensitive) or a regex. Order matters — first match wins.
  @operational [
    {"server restarted", :server_restart},
    {"rate-limited", :rate_limited},
    {"api was overloaded", :rate_limited},
    {"usage limit reached", :quota_exhausted},
    {"could not authenticate", :auth_failure},
    {"credentials exp", :auth_failure},
    {":awaiting_review_timeout", :review_timeout},
    {":merge_failed", :merge_failed},
    {":mr_closed", :merge_failed},
    {"merge_failed", :merge_failed},
    {"worker spawn failed after registration", :spawn_failure},
    {":inspect_worktree_failed", :spawn_failure},
    {":fetch_failed", :spawn_failure},
    {":worktree_failed", :spawn_failure}
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

  # Typed terminal causes that carry an unambiguous verdict, mapped to
  # {class, subcategory}. Mostly `Arbiter.Worker.StopReason` categories, plus
  # the commit-gate parks. Deliberately partial: `:crashed`
  # ("non-zero exit, no recognized signature"), `:stalled` (no output, cause
  # unknown) and `:missing_worktree` (needs a provisioning investigation, not
  # a class) say nothing on their own, so they are absent here and fall
  # through to the transcript/label path rather than being force-bucketed.
  @stop_category_map %{
    auth_expired: {:operational, :auth_failure},
    quota_exhausted: {:operational, :quota_exhausted},
    credit_exhausted: {:operational, :credit_exhausted},
    rate_limited: {:operational, :rate_limited},
    gateway_error: {:operational, :gateway_error},
    stream_schema_drift: {:operational, :stream_schema_drift},
    killed: {:operational, :killed},
    spawn_exec_failed: {:operational, :spawn_failure},
    spawn_failed: {:operational, :spawn_failure},
    context_thrash: {:agent_quality, :context_exhaustion},
    exited_without_done: {:agent_quality, :never_signalled_done},
    # Commit-gate parks (bd-apwfmy). Not `StopReason` categories — the
    # subprocess exited cleanly and the *work* is what failed — but they share
    # the column because they are the run's typed terminal cause, and they are
    # exactly the agent-quality cases the parent issue asked to classify
    # without a regex.
    uncommitted_at_completion: {:agent_quality, :uncommitted_at_completion},
    no_commits_at_completion: {:agent_quality, :no_commits_at_completion},
    secret_in_commit: {:agent_quality, :secret_in_commit}
  }

  @doc """
  The `Arbiter.Worker.StopReason` categories `classify/3` will trust on their
  own, as a `%{category => {class, subcategory}}` map. Exposed so callers
  (notably `Arbiter.Loop.Corpus`) can tell in advance whether a run still
  needs its transcript read.
  """
  @spec conclusive_stop_categories() :: %{atom() => {class(), atom()}}
  def conclusive_stop_categories, do: @stop_category_map

  @doc """
  Classify a failed run from its `failure_reason` and the transcript's terminal
  lines (a list of strings — pass `[]` when no transcript is available).
  """
  @spec classify(String.t() | nil, [String.t()]) :: result()
  def classify(failure_reason, transcript_lines),
    do: classify(failure_reason, transcript_lines, [])

  @doc """
  Classify a failed run, preferring structured evidence over a transcript scan.

  ## Options

    * `:stop_category` — the run's typed `Arbiter.Worker.StopReason` category
      (`worker_runs.stop_category`), as an atom or the string read back off the
      column. When it is one of `conclusive_stop_categories/0` it decides the
      verdict outright and no transcript is consulted. Anything else (nil, an
      ambiguous category, a value from a newer/older Arbiter) is ignored and
      the transcript/label path runs exactly as before.

  """
  @spec classify(String.t() | nil, [String.t()], keyword()) :: result()
  def classify(failure_reason, transcript_lines, opts)
      when is_list(transcript_lines) and is_list(opts) do
    {label_class, label_sub} = label_of(failure_reason)
    have_transcript? = transcript_lines != []

    case conclusive_stop_category(Keyword.get(opts, :stop_category)) do
      {class, sub} ->
        final(class, sub, label_class, :stop_category)

      nil ->
        context? = context_exhaustion?(transcript_lines)
        api_error? = api_error_signal?(transcript_lines)
        proxy_5xx? = proxy_5xx?(transcript_lines)

        cond do
          # Transcript wins: a context-exhaustion thrash with no genuine API error
          # is agent-quality no matter what the label claimed.
          context? and not api_error? ->
            final(:agent_quality, :context_exhaustion, label_class, :transcript)

          # Transcript wins: a proxy 5xx (infrastructure failure) overrides any label
          # and classifies as operational, even if labelled as unknown.
          proxy_5xx? ->
            final(:operational, :proxy_5xx, label_class, :transcript)

          true ->
            # No structured or transcript override — trust the allowlist label.
            final(
              label_class,
              label_sub,
              label_class,
              if(have_transcript?, do: :transcript, else: :label)
            )
        end
    end
  end

  # Accepts the atom or the string the SQLite column hands back. Never
  # `String.to_atom/1` on it — an unrecognised value is simply not conclusive.
  defp conclusive_stop_category(nil), do: nil

  defp conclusive_stop_category(category) when is_atom(category),
    do: Map.get(@stop_category_map, category)

  defp conclusive_stop_category(category) when is_binary(category) do
    Enum.find_value(@stop_category_map, fn {known, verdict} ->
      if Atom.to_string(known) == category, do: verdict
    end)
  end

  defp conclusive_stop_category(_other), do: nil

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

  # Narrow, unambiguous infra-fingerprint substrings (lowercased) — they can
  # only come from Arbiter's own infrastructure, never from application code
  # or prose the agent was reading, so a full-transcript scan for these
  # carries no false-positive risk. Exposed via `infra_fingerprints/0` so
  # `Arbiter.Loop.Corpus` can scan whole transcripts for them without
  # duplicating the list.
  @infra_fingerprints [
    "phoenix.ecto.pendingmigrationerror",
    "dbconnection.connectionerror"
  ]

  @doc """
  The narrow infra-fingerprint substrings `proxy_5xx?/1` matches on. See the
  module doc's "Read discipline" note on `Arbiter.Loop.Corpus` — these are
  the only patterns Corpus scans a whole transcript for (versus the bounded
  tail read used for everything else).
  """
  @spec infra_fingerprints() :: [String.t()]
  def infra_fingerprints, do: @infra_fingerprints

  @doc """
  True when a line shows Arbiter's own infrastructure (proxy, database, etc.)
  has failed. These are distinct from Anthropic API failures and must be
  classified as operational, routed to ops, and excluded from
  prompt-shaping. Detects by specific error classes (Phoenix/Ecto, DBConnection)
  that are unambiguous markers of Arbiter's own infrastructure failure.
  """
  @spec proxy_5xx?([String.t()]) :: boolean()
  def proxy_5xx?(transcript_lines) do
    Enum.any?(transcript_lines, fn line ->
      l = String.downcase(line)
      Enum.any?(@infra_fingerprints, &String.contains?(l, &1))
    end)
  end

  # --- internals ---------------------------------------------------------

  # `evidence` is what actually decided the verdict. Anything other than
  # `:label` means we had corroborating evidence, which is what gives the
  # disagreement rate its denominator — a structured verdict counts even
  # though it read no transcript.
  defp final(final_class, subcategory, label_class, evidence) do
    reclassified = final_class != label_class
    corroborated = evidence != :label

    corroboration =
      cond do
        not corroborated -> :unavailable
        reclassified -> :disagree
        true -> :agree
      end

    %{
      class: final_class,
      subcategory: subcategory,
      label_class: label_class,
      reclassified: reclassified,
      corroborated: corroborated,
      corroboration: corroboration,
      evidence: evidence
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
