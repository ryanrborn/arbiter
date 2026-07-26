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

  @doc "Whether a verdict's findings text discloses `VERIFICATION: PARTIAL`."
  @spec partial?(String.t() | nil) :: boolean()
  def partial?(findings) when is_binary(findings), do: Regex.match?(@verification_partial, findings)
  def partial?(_), do: false

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
end
