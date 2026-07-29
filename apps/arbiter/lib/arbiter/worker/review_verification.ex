defmodule Arbiter.Worker.ReviewVerification do
  @moduledoc """
  The `VERIFICATION: FULL` / `VERIFICATION: PARTIAL` reviewer disclosure
  protocol (bd-4te55l), shared across every reviewer-consuming path so the
  prompt text, detection regex, and warning banner can't fork the way they did
  before bd-1j5x6u: `Arbiter.Worker.ReviewGate`'s in-band round loop had it,
  `Arbiter.Worker.Dispatch`'s coordinator-dispatched `review_prompt/2` (consumed
  by `Arbiter.Worker.route_reviewer_completion/1`) did not.
  """

  @verification_partial ~r/^\s*VERIFICATION:\s*PARTIAL\b/im

  # A single per-criterion line of the CRITERIA breakdown (bd-4yhv4x): a list
  # item (`-`, `*`, or `1.`/`1)`) whose first token is a bracketed outcome —
  # `[MET]`, `[NOT MET]`, or `[N/A]`. The alternation lists `NOT MET` after
  # `MET`, but each anchors to the `[` so `[NOT MET]` can never be mis-read as
  # `[MET]` (the `M`-first branch fails on the leading `N`).
  @criteria_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*(MET|NOT\s+MET|N\/?A)\s*\]/im
  @criteria_unmet ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]/im

  @doc "Whether a verdict's findings text discloses `VERIFICATION: PARTIAL`."
  @spec partial?(String.t() | nil) :: boolean()
  def partial?(findings) when is_binary(findings), do: Regex.match?(@verification_partial, findings)
  def partial?(_), do: false

  @doc """
  Whether the findings text carries a per-criterion CRITERIA breakdown at all —
  i.e. at least one `- [MET] / [NOT MET] / [N/A]` line. Distinguishes "the
  reviewer addressed the criteria individually" from a plain prose verdict.
  """
  @spec criteria_present?(String.t() | nil) :: boolean()
  def criteria_present?(findings) when is_binary(findings),
    do: Regex.match?(@criteria_line, findings)

  def criteria_present?(_), do: false

  @doc """
  Whether the CRITERIA breakdown marks at least one criterion `- [NOT MET]`.
  This is the core of the unmet-criteria guard (bd-4yhv4x): an APPROVE whose own
  breakdown admits an unmet criterion must NOT clean-merge.
  """
  @spec unmet_criteria?(String.t() | nil) :: boolean()
  def unmet_criteria?(findings) when is_binary(findings),
    do: Regex.match?(@criteria_unmet, findings)

  def unmet_criteria?(_), do: false

  @doc """
  Count the CRITERIA breakdown as `{total, unmet}` — total per-criterion lines
  and how many are `[NOT MET]`. Returns `{nil, nil}` when no breakdown is
  present, so callers can tell "no criteria addressed" apart from "all met"
  (`{n, 0}`). Recorded structurally on each review round so "APPROVE with N
  criteria unmet" is queryable (bd-4yhv4x / bd-aqyjuc).
  """
  @spec criteria_counts(String.t() | nil) :: {non_neg_integer(), non_neg_integer()} | {nil, nil}
  def criteria_counts(findings) when is_binary(findings) do
    total = length(Regex.scan(@criteria_line, findings))

    if total == 0 do
      {nil, nil}
    else
      {total, length(Regex.scan(@criteria_unmet, findings))}
    end
  end

  def criteria_counts(_), do: {nil, nil}

  @doc """
  Whether a line is part of the CRITERIA breakdown. Used to strip breakdown
  lines when counting *findings* (a `- [NOT MET]` line otherwise reads as a
  bulleted finding to the generic finding-item regex).
  """
  @spec criteria_line?(String.t()) :: boolean()
  def criteria_line?(line) when is_binary(line), do: Regex.match?(@criteria_line, line)
  def criteria_line?(_), do: false

  @doc """
  The anti-stale-reflag instruction: a finding is only valid if re-confirmed
  against the CURRENT diff, not recalled from a prior review round or memory.
  """
  @spec anti_stale_reflag_block() :: String.t()
  def anti_stale_reflag_block do
    """
    *** DO NOT draft findings early and flush them unchanged once a wait is
    abandoned. A finding is only valid if you can point to the CURRENT diff (not
    a memory of it, not a prior review round's text) and show the problem is
    still there. Before including ANY finding — especially one that echoes
    something you (or a prior round) already flagged — re-open the CURRENT file
    at the cited line and confirm the problem is still present RIGHT NOW. If the
    code has already been fixed, DROP the finding; re-flagging already-fixed
    code as broken is worse than no finding at all — it wastes an implementer
    round on nothing.
    """
  end

  @doc """
  The disclosure protocol instruction: the reviewer must state whether its
  findings were freshly, fully confirmed or whether verification was abandoned
  partway.
  """
  @spec disclosure_block() :: String.t()
  def disclosure_block do
    """
    Immediately after your findings, print exactly one of:

        VERIFICATION: FULL
        VERIFICATION: PARTIAL — <one-line reason>

    Use `VERIFICATION: FULL` only if every finding above was freshly confirmed
    against the CURRENT diff (and, if you ran them, tests/build completed and you
    read their real output). Use `VERIFICATION: PARTIAL` if you gave up on any
    check (e.g. abandoned a slow `mix test` wait) before finalizing — name what
    you couldn't confirm. This is not optional and is not a formality: a verdict
    marked PARTIAL is re-verified or clearly flagged before anyone acts on it, so
    mark it honestly rather than defaulting to FULL.
    """
  end

  @doc """
  The per-criterion CRITERIA breakdown instruction (bd-4yhv4x): the reviewer
  must address each stated acceptance criterion individually as part of the
  verdict payload — met / not met / N/A with evidence — not bury the judgement
  in prose. Emitted only when the task actually has acceptance criteria. Also
  hammers the "tests pass ≠ criteria met" distinction, including the bd-7rspia
  failure mode (tests asserting against a test-local helper rather than the real
  code path).
  """
  @spec criteria_block() :: String.t()
  def criteria_block do
    """
    After the `VERDICT:` line and before your prose findings, print a CRITERIA
    breakdown that addresses EACH stated acceptance criterion on its own line:

        CRITERIA:
        - [MET] <criterion> — <specific evidence: the file:line / test that satisfies it>
        - [NOT MET] <criterion> — <what is missing or wrong>
        - [N/A] <criterion> — <why it does not apply>

    Rules — this is the verdict payload, not a formality:
    - One line per criterion; use exactly one of `[MET]`, `[NOT MET]`, `[N/A]`.
    - "Met" means the criterion is actually SATISFIED by the diff, not merely
      that the code looks clean or that some test is green. Tests passing is NOT
      the same as a criterion being met: a test can assert against a test-local
      helper or stub instead of the real serializer / code path the criterion
      names, or exercise a feature that is inert in production. Trace each
      criterion to the real behaviour and cite where it is delivered.
    - If the implementer declared a limitation, deferral, or "out of scope" that
      touches a stated criterion, that criterion is `[NOT MET]` — do not launder
      a declared gap into an approval.
    - Do NOT mark a criterion `[MET]` unless you verified it against the CURRENT
      diff. An APPROVE whose breakdown contains any `[NOT MET]` line will not be
      accepted as final — mark honestly.
    """
  end

  @doc """
  Prepend the loud "issued without full verification" warning banner to a
  verdict's findings text, right after the `VERDICT:` line, so it travels with
  the findings into the durable thread, any revise prompt, and any escalation
  payload — impossible to miss, unlike a verdict accepted silently at face
  value.
  """
  @spec prepend_banner(String.t()) :: String.t()
  def prepend_banner(findings) when is_binary(findings) do
    case String.split(findings, "\n", parts: 2) do
      [verdict_line, rest] -> verdict_line <> "\n\n" <> banner_text() <> "\n\n" <> rest
      [verdict_line] -> verdict_line <> "\n\n" <> banner_text()
    end
  end

  @doc "The warning banner text itself. Public for inspection in tests."
  @spec banner_text() :: String.t()
  def banner_text do
    "⚠️ ISSUED WITHOUT FULL VERIFICATION — the reviewer disclosed `VERIFICATION: PARTIAL` " <>
      "(it abandoned test/build verification, e.g. gave up waiting on a test run, before " <>
      "finalizing this verdict). Weight the findings below accordingly: confirm each one " <>
      "against the CURRENT diff before acting — do not assume they were freshly re-checked."
  end

  @doc """
  Prepend the "unmet acceptance criteria" banner to a verdict's findings text,
  right after the `VERDICT:` line, so a rejected-for-unmet-criteria payload
  carries the reason (and the count) into the durable thread, the revise prompt,
  and any escalation. `unmet`/`total` label how many criteria the reviewer's own
  breakdown marked `[NOT MET]`.
  """
  @spec prepend_criteria_banner(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def prepend_criteria_banner(findings, unmet, total)
      when is_binary(findings) and is_integer(unmet) and is_integer(total) do
    banner = criteria_banner_text(unmet, total)

    case String.split(findings, "\n", parts: 2) do
      [verdict_line, rest] -> verdict_line <> "\n\n" <> banner <> "\n\n" <> rest
      [verdict_line] -> verdict_line <> "\n\n" <> banner
    end
  end

  @doc "The unmet-criteria banner text. Public for inspection in tests."
  @spec criteria_banner_text(non_neg_integer(), non_neg_integer()) :: String.t()
  def criteria_banner_text(unmet, total) do
    "⚠️ ACCEPTANCE CRITERIA NOT MET — the reviewer approved on code quality but its own " <>
      "CRITERIA breakdown marks #{unmet} of #{total} acceptance criteria `[NOT MET]`. " <>
      "\"Tests pass\" is not \"criteria met\": this work does not satisfy the task as stated " <>
      "and must NOT be treated as a clean, mergeable APPROVE. Address the unmet criteria " <>
      "below before this can merge."
  end

  @doc """
  Prepend the "no CRITERIA breakdown" banner to a verdict's findings text, right
  after the `VERDICT:` line (bd-4yhv4x). Used when a criteria-bearing task is
  APPROVEd with no per-criterion breakdown at all — a holistic judgement that
  never accounted for the acceptance criteria, the original bug's exact shape.
  """
  @spec prepend_missing_criteria_banner(String.t()) :: String.t()
  def prepend_missing_criteria_banner(findings) when is_binary(findings) do
    banner = missing_criteria_banner_text()

    case String.split(findings, "\n", parts: 2) do
      [verdict_line, rest] -> verdict_line <> "\n\n" <> banner <> "\n\n" <> rest
      [verdict_line] -> verdict_line <> "\n\n" <> banner
    end
  end

  @doc "The missing-CRITERIA-breakdown banner text. Public for inspection in tests."
  @spec missing_criteria_banner_text() :: String.t()
  def missing_criteria_banner_text do
    "⚠️ ACCEPTANCE CRITERIA NOT ADDRESSED — this task has stated acceptance criteria, but the " <>
      "reviewer approved WITHOUT a per-criterion CRITERIA breakdown: it judged the code " <>
      "holistically and never accounted for whether the work delivers what was asked. This is " <>
      "the exact failure the gate exists to catch. The approval is NOT accepted as a clean, " <>
      "mergeable verdict — each acceptance criterion must be addressed individually (met / not " <>
      "met / N/A with evidence) before this can merge."
  end
end
