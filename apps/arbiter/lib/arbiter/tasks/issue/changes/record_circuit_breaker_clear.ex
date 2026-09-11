defmodule Arbiter.Tasks.Issue.Changes.RecordCircuitBreakerClear do
  @moduledoc """
  Watermarks the PR head SHA in effect whenever a coordinator resumes a
  circuit-broken engagement (`circuit_breaker_tripped: true -> false`,
  bd-1atwts).

  Tripping deliberately posts nothing, so nothing about the trip advances the
  head, `last_verdict`, or `last_verdict_sha` — a bare flag clear (what
  `arb update <id> --resume-review` sends) restores the exact state that
  tripped the breaker, and both trip predicates in
  `Arbiter.Workflows.ReviewPatrol` (`disputed_re_request?/3`, `run_rereview/5`'s
  same-SHA guard, and `loop_signature_reason/3`) would re-evaluate true on the very next
  tick, re-escalating and writing a second `Reviews.Record`.

  The watermark is `circuit_breaker_sha` — the head the breaker actually
  tripped at (bd-wtvu9r), recorded on the trip. It falls back to
  `last_verdict_sha` for engagements tripped before that field existed: the
  two bd-1atwts arms only trip when `head == last_verdict_sha`, so for them
  the two are the same SHA. The answered-findings arm trips on a head that has
  moved PAST the verdicted commit, where they are not: watermarking
  `last_verdict_sha` there would stamp the wrong (older) commit and the next
  tick would re-trip. Stamp it onto `circuit_breaker_cleared_sha` at the
  moment of the clear, and every predicate treats `head == circuit_breaker_cleared_sha` as
  "a coordinator already adjudicated this exact commit, don't re-trip". The
  watermark stops mattering the moment a new commit moves the head.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    resuming? =
      Changeset.changing_attribute?(changeset, :circuit_breaker_tripped) and
        changeset.data.circuit_breaker_tripped == true and
        Changeset.get_attribute(changeset, :circuit_breaker_tripped) == false

    if resuming? do
      Changeset.force_change_attribute(
        changeset,
        :circuit_breaker_cleared_sha,
        changeset.data.circuit_breaker_sha || changeset.data.last_verdict_sha
      )
    else
      changeset
    end
  end
end
