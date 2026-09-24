defmodule Arbiter.Reviews.GuardRegistry do
  @moduledoc """
  One declared row per review/merge guard. Declarative only — nothing here runs
  at request time (P8 of `docs/review-coverage-and-guard-policy.md`, design
  #1635 §5.4).

  ## Why this exists

  The investigation behind #1635 found the same failure shape sixteen times: a
  guard was added to stop an incident, the guard misfired, and the misfire cost
  more than the incident (`$325.82` across chain A alone). §5.1 states the
  policy as four invariants — every refusal has a finite bound (I1), a guard
  never strands approved work as a failed run (I2), one escalation per episode
  (I3), and:

  > **I4 — A guard that is not in the registry does not exist.**

  This module is that registry. It is modelled on
  `Arbiter.Worker.ReviewGate`'s `@verdict_guards` list, which already proves the
  pattern works for four guards: one table, one row per guard, and a test that
  raises rather than defaulting when a name is missing.

  A row is a *declaration*, not a mechanism: it records what the guard's bound,
  episode key and terminal state **are today**, so the two tests in
  `test/arbiter/reviews/guard_registry_test.exs` can hold the line.

  ## Row fields

    * `:id` — the registry's own name for the guard.
    * `:doc_ref` — the §2 inventory id (`"G1"`, `"W7"`, `"M3"`, …). Every one of
      §2's 60 rows appears here exactly once.
    * `:class` — `:a`–`:f`, per §5.3. `:class_source` is `:doc` when §5.3 names
      the guard explicitly and `:inferred` when it does not; every `:inferred`
      row carries a `:class_note` giving the reasoning.
    * `:bound` — `{unit, n}` with `n` a positive integer, or `{unit, {:config,
      name}}` when the bound is a module attribute / resolver function (`name`
      must then also appear in `:anchors`). `{unit, :unbounded}` records a guard
      that has **no** bound today; it is a policy violation and may only appear
      on a row listed in `known_violations/0`.
    * `:episode` — I3's reset condition, as a tuple of the keys the escalation is
      deduped on. `R5`'s atomic claim is the reference implementation.
    * `:terminal` — where the guard leaves the work once its bound is spent:

          :proceeds     fails open — the work continues in its last good state
          :skipped      this tick is skipped; the next one re-evaluates
          :parked       parked and still watched; no further action issued
          :escalated_once  one page, then no further action
          :resumed      fails the run only to hand it to auto-resume
          :frozen       blocked until a human or config change
          :given_up     terminal refusal, recorded as such
          :failed_run   converts a guard *misfire* into `Run.status = :failed`
                        — an I2 violation; must be in `known_violations/0`
          :failed_run_by_design
                        fails the run because the work genuinely did not happen
                        (nothing was committed); requires a `:policy_note`
          :retries_forever
                        re-issues its action with no terminal state — an I1
                        violation; must be in `known_violations/0`

    * `:sites` — `{module, function, arity}` for the code the row governs. Every
      site must still exist; a row pointing at a deleted function fails the
      suite.
    * `:anchors` — source substrings (attribute names, reason atoms) that must
      still appear in the site module. This is how a bound stays anchored
      without a line number.

  ## How completeness is enforced

  The mechanism is an **AST scan**, `Arbiter.Test.GuardRefusalScan` — not an
  `@guard` attribute on each guard function. An attribute only fails the suite
  when someone adds the attribute and forgets the row, which is the easy half of
  the mistake; the scan fails when someone adds a refusal path *at all*. It
  reads the source of every module in `control_plane/0` and reports the function
  each refusal originates in, using three syntactic signals (refusal-shaped
  function name, a call to a refusal primitive such as `Worker.fail/2` or
  `CoordinatorNotifier.*`, and a returned `{:error, {tag, …}}` tuple — see that
  module's docs for the exact rules and their two deliberate exclusions).

  The test then requires every detected site to be **accounted for**: either it
  is some row's `:site`, or it is listed in the test's own
  `@non_guard_sites` table with a reason. Both halves are asserted to be free of
  stale entries, so neither list can rot. Adding an escalation or a
  `Worker.fail/2` anywhere in the six modules therefore fails
  `guard_registry_test.exs` until it is declared.

  ## Known violations

  `known_violations/0` records the rows that **violate the policy today**, with
  their current behaviour and the phase that removes them. P8 does not fix
  them — recording them is the point, because an exemption list that is
  enumerated, tested and only allowed to shrink is a schedule, whereas an
  unwritten one is the status quo. The test freezes the id set: an entry may be
  removed, never added.
  """

  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workflows.MergeQueue
  alias Arbiter.Workflows.PRPatrol
  alias Arbiter.Workflows.ReviewPatrol

  @type class :: :a | :b | :c | :d | :e | :f
  @type bound_unit ::
          :attempts
          | :deferrals
          | :escalations
          | :evaluations
          | :polls
          | :retries
          | :reviews
          | :rounds
  @type bound :: {bound_unit(), pos_integer() | {:config, atom()} | :unbounded}
  @type site :: {module(), atom(), arity()}
  @type terminal ::
          :proceeds
          | :skipped
          | :parked
          | :escalated_once
          | :resumed
          | :frozen
          | :given_up
          | :failed_run
          | :failed_run_by_design
          | :retries_forever

  @type row :: %{
          required(:id) => atom(),
          required(:doc_ref) => String.t(),
          required(:class) => class(),
          required(:class_source) => :doc | :inferred,
          required(:bound) => bound(),
          required(:episode) => tuple(),
          required(:terminal) => terminal(),
          required(:sites) => [site()],
          required(:anchors) => [String.t()],
          required(:summary) => String.t(),
          optional(:class_note) => String.t(),
          optional(:policy_note) => String.t()
        }

  @classes [:a, :b, :c, :d, :e, :f]

  @class_policies %{
    a: %{name: "merge authorisation", disposition: :fail_closed},
    b: %{name: "review admissibility", disposition: :fail_open},
    c: %{name: "verdict integrity", disposition: :closed_on_content_open_on_liveness},
    d: %{name: "progress", disposition: :fail_open},
    e: %{name: "remediation", disposition: :fail_open},
    f: %{name: "filing & escalation", disposition: :fail_closed}
  }

  @terminals [
    :proceeds,
    :skipped,
    :parked,
    :escalated_once,
    :resumed,
    :frozen,
    :given_up,
    :failed_run,
    :failed_run_by_design,
    :retries_forever
  ]

  @bound_units [
    :attempts,
    :deferrals,
    :escalations,
    :evaluations,
    :polls,
    :retries,
    :reviews,
    :rounds
  ]

  # The modules the freeze covers, with the scan signals each one's refusals
  # are visible through. See `Arbiter.Test.GuardRefusalScan` for why
  # `Arbiter.Worker` omits `:tagged`.
  @control_plane [
    %{
      module: ReviewGate,
      path: "apps/arbiter/lib/arbiter/worker/review_gate.ex",
      signals: [:name, :prim, :tagged]
    },
    %{
      module: Watchdog,
      path: "apps/arbiter/lib/arbiter/worker/watchdog.ex",
      signals: [:name, :prim, :tagged]
    },
    %{
      module: MergeQueue,
      path: "apps/arbiter/lib/arbiter/workflows/merge_queue.ex",
      signals: [:name, :prim, :tagged]
    },
    %{
      module: Worker,
      path: "apps/arbiter/lib/arbiter/worker.ex",
      signals: [:name, :prim]
    },
    %{
      module: ReviewPatrol,
      path: "apps/arbiter/lib/arbiter/workflows/review_patrol.ex",
      signals: [:name, :prim, :tagged]
    },
    %{
      module: PRPatrol,
      path: "apps/arbiter/lib/arbiter/workflows/pr_patrol.ex",
      signals: [:name, :prim, :tagged]
    }
  ]

  # ---------------------------------------------------------------------------
  # §2.1 `review_gate.ex` — the in-process gate (G1–G17)
  # ---------------------------------------------------------------------------
  @review_gate_guards [
    %{
      id: :pre_spawn_commit_check,
      doc_ref: "G1",
      class: :b,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :review_id, :round},
      terminal: :proceeds,
      sites: [
        {ReviewGate, :reviewer_commit_check, 1},
        {ReviewGate, :escalate_pre_review, 3},
        {ReviewGate, :handle_continue, 2},
        {ReviewGate, :spawn_reviewer_after_update, 1}
      ],
      anchors: ["reviewer_commit_check", "escalate_pre_review"],
      summary: "branch has commits ahead of target before a reviewer is paid for",
      policy_note:
        "A git error fails open (proceed). A genuine `{:ok, false}` escalates and " <>
          "the run does fail — but that is a branch with no work on it, not a misfire, " <>
          "so it is not an I2 violation."
    },
    %{
      id: :empty_diff_range,
      doc_ref: "G2",
      class: :b,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :empty_diff_guard, 1},
        {ReviewGate, :escalate_pre_review, 3}
      ],
      anchors: ["empty_diff_guard"],
      summary: "base_sha == head_sha — the target already absorbed the commits"
    },
    %{
      id: :reviewing_timeout,
      doc_ref: "G3",
      class: :c,
      class_source: :inferred,
      class_note:
        "§5.3 lists G5–G13 under class C and does not place G3. A reviewing-pass " <>
          "timeout produces `:no_verdict`, which is exactly the liveness half of " <>
          "class C (never fail the run), so it is classed with the rest of the " <>
          "no-verdict family.",
      bound: {:retries, {:config, :default_timeout_retries}},
      episode: {:task, :review_id, :attempt},
      terminal: :parked,
      sites: [
        {ReviewGate, :handle_info, 2},
        {ReviewGate, :escalate_timeout, 1}
      ],
      anchors: ["@default_timeout_retries", "timeout_retries_left"],
      summary: "reviewing-pass timeout, with one fresh-mind retry"
    },
    %{
      id: :timeout_no_verdict,
      doc_ref: "G4",
      class: :c,
      class_source: :inferred,
      class_note: "The shape of G3's report rather than a separate budget; classed with it.",
      bound: {:evaluations, 1},
      episode: {:task, :review_id, :attempt},
      terminal: :escalated_once,
      sites: [{ReviewGate, :escalate_timeout, 1}],
      anchors: [":timed_out", ":no_verdict"],
      summary: "a timeout reports :no_verdict, never a synthetic :request_changes",
      policy_note:
        "Reports `:no_verdict`; the conversion into `Run.status = :failed` belongs " <>
          "to C2 (`fail_reason_for/1`) and is recorded as G3's terminal state, not " <>
          "counted twice here."
    },
    %{
      id: :reviewer_print_timeout_rotation,
      doc_ref: "G19",
      class: :c,
      class_source: :inferred,
      class_note:
        "§5.3 lists G5–G13 under class C and does not place G19 (it postdates the " <>
          "table). A pool-wide print-timeout produces no verdict at all and parks " <>
          "without faulting the work, which is exactly class C's liveness half — it " <>
          "is classed with G3/G4, the rest of the reviewer-timeout family.",
      bound: {:attempts, {:config, :review_agent}},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :handle_reviewer_print_timeout, 2},
        {ReviewGate, :escalate_pool_exhausted, 2}
      ],
      anchors: ["review_agent", "reviewer_timeouts", "next_reviewer_provider"],
      summary:
        "a reviewer print-timeout rotates to the next review_agent.type provider, " <>
          "at most one pass per pool entry per round",
      policy_note:
        "bd-3hb4ih. The bound is the CONFIGURED POOL SIZE, not a retry count: each " <>
          "provider gets at most one pass per round, because a provider that timed " <>
          "out is subtracted from the candidates (`reviewer_timeouts`) and the " <>
          "rotation refuses outright once as many timeouts are recorded as the pool " <>
          "has entries. A pool of one never rotates and keeps G3/G4's terminal " <>
          "unchanged. The list resets per ROUND: a new round reviews a different " <>
          "diff, so a provider that timed out on the previous one starts even again."
    },
    %{
      id: :empty_net_diff_approval,
      doc_ref: "G20",
      class: :b,
      class_source: :inferred,
      class_note:
        "Same shape as G2, which §5.3 classes `b`: the target has already absorbed the " <>
          "branch's contribution, so the park is an honest completion, not a misfire — " <>
          "only the detection differs (content emptiness, not SHA equality).",
      bound: {:evaluations, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :finalize_approval, 3}
      ],
      anchors: ["finalize_approval", "coverage_net_diff_id(state)"],
      summary:
        "bd-aq81qz: an APPROVE whose net diff against the target is empty — commits " <>
          "exist (head_sha != base_sha, so G2 does not fire) but contribute nothing, e.g. " <>
          "already-squashed commits plus a merge of the target back in. Reuses " <>
          "`coverage_net_diff_id/1`'s `{:error, :no_net_diff}` answer (the same check the " <>
          "coverage row itself would fail on) rather than deriving emptiness twice"
    },
    %{
      id: :verdict_parse,
      doc_ref: "G5",
      class: :c,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :review_id, :attempt},
      terminal: :escalated_once,
      sites: [
        {ReviewGate, :parse_verdict, 3},
        {ReviewGate, :parse_verdict, 1}
      ],
      anchors: ["@verdict_approve"],
      summary: "VERDICT: line parsed from memory, then the durable transcript"
    },
    %{
      id: :verdict_reprompt_budget,
      doc_ref: "G6",
      class: :c,
      class_source: :doc,
      bound: {:retries, {:config, :default_verdict_retries}},
      episode: {:task, :review_id, :attempt},
      terminal: :parked,
      sites: [{ReviewGate, :maybe_reprompt, 2}],
      anchors: ["@default_verdict_retries"],
      summary: "one re-prompt when no verdict could be parsed"
    },
    %{
      id: :transcript_recovery,
      doc_ref: "G7",
      class: :c,
      class_source: :doc,
      bound: {:attempts, 1},
      episode: {:task, :review_id, :attempt},
      terminal: :proceeds,
      sites: [{ReviewGate, :recover_verdict_from_scans, 1}],
      anchors: ["recover_verdict_from_scans"],
      summary: "last-ditch transcript recovery before conceding :no_verdict"
    },
    %{
      id: :empty_findings,
      doc_ref: "G8",
      class: :c,
      class_source: :doc,
      bound: {:retries, {:config, :default_verdict_retries}},
      episode: {:task, :review_id, :attempt},
      terminal: :parked,
      sites: [{ReviewGate, :findings_present?, 1}],
      anchors: ["findings_present?", "@default_verdict_retries"],
      summary: "REQUEST_CHANGES with no actionable findings shares G6's budget"
    },
    %{
      id: :partial_verification,
      doc_ref: "G9",
      class: :c,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :verdict_guard_spec, 2},
        {ReviewGate, :run_verdict_guard, 4}
      ],
      anchors: [":partial_verification", "@verdict_guards"],
      summary: "VERIFICATION: PARTIAL is re-prompted once, then bannered"
    },
    %{
      id: :unaddressed_findings,
      doc_ref: "G10",
      class: :c,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :verdict_guard_spec, 2},
        {ReviewGate, :run_verdict_guard, 4}
      ],
      anchors: [":unaddressed_findings", "@verdict_guards"],
      summary: "an APPROVE that never revisits its own open finding"
    },
    %{
      id: :unmet_criteria,
      doc_ref: "G11",
      class: :c,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :verdict_guard_spec, 2},
        {ReviewGate, :run_verdict_guard, 4}
      ],
      anchors: [":unmet_criteria", "@verdict_guards"],
      summary: "an APPROVE carrying a [NOT MET] criterion"
    },
    %{
      id: :missing_criteria,
      doc_ref: "G12",
      class: :c,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :verdict_guard_spec, 2},
        {ReviewGate, :run_verdict_guard, 4}
      ],
      anchors: [":missing_criteria", "@verdict_guards"],
      summary: "a bare holistic APPROVE with no criteria breakdown"
    },
    %{
      id: :verdict_guard_dispatcher,
      doc_ref: "G13",
      class: :c,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :escalated_once,
      sites: [
        {ReviewGate, :run_verdict_guard, 4},
        {ReviewGate, :fail_closed, 3}
      ],
      anchors: ["@verdict_guards", "verdict_guard_names"],
      summary: "the shared retry-vs-fail-closed dispatcher behind G9–G12",
      policy_note:
        "The dispatcher itself has no terminal state of its own: the run-failure " <>
          "is recorded on each of G9–G12, which is where §2.6 counts it."
    },
    %{
      id: :round_budget,
      doc_ref: "G14",
      class: :d,
      class_source: :doc,
      bound: {:rounds, {:config, :default_rounds}},
      episode: {:task, :review_id, :round},
      terminal: :failed_run,
      sites: [
        {ReviewGate, :do_route_after_reject, 2},
        {ReviewGate, :terminal_reject_verdict, 1}
      ],
      anchors: ["@default_rounds", "@rounds_by_difficulty"],
      summary: "review<->revise round budget, capped per difficulty",
      policy_note:
        "P9 split this arm. A verdict guard that refused an APPROVE and reached " <>
          "the cap now parks (`terminal_reject_verdict/1` -> class C); what still " <>
          "reaches `:failed_run` is a reviewer that really said REQUEST_CHANGES for " <>
          "every round, which §5.3 would also park (class D) and P9's AC1 " <>
          "deliberately left alone. The remaining half is recorded below."
    },
    %{
      id: :commit_gate_head_unchanged,
      doc_ref: "G15",
      class: :d,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :commit_gate_outcome, 3},
        {ReviewGate, :finish_revise, 1},
        {ReviewGate, :nudge_uncommitted_implementer, 1}
      ],
      anchors: ["commit_gate_outcome"],
      summary: "HEAD unchanged after a fix round: nudge once, never re-review an identical diff"
    },
    %{
      id: :commit_gate_escalation,
      doc_ref: "G16",
      class: :d,
      class_source: :doc,
      bound: {:escalations, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :escalate_commit_gate, 2},
        {ReviewGate, :escalate_no_changes, 1}
      ],
      anchors: ["@commit_gate_no_changes_marker", "@commit_gate_uncommitted_marker"],
      summary:
        "the commit-gate escalation shapes (uncommitted, no changes, " <>
          "approval-gap no-op, and a non-file fix stalled twice in a row)"
    },
    %{
      id: :reviewed_sha_stamp,
      doc_ref: "G17",
      class: :a,
      class_source: :inferred,
      class_note:
        "§5.3's class A is the merge-authorisation family; the stamp is the write " <>
          "that family reads, so it is classed with it even though §5.3 lists only " <>
          "the readers (W1–W7, M1–M3).",
      bound: {:attempts, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{ReviewGate, :stamp_reviewed_head, 1}],
      anchors: ["stamp_reviewed_head"],
      summary: "best-effort reviewed-SHA stamp on APPROVE"
    },
    %{
      id: :pre_review_push,
      doc_ref: "G18",
      class: :b,
      class_source: :doc,
      bound: {:attempts, 1},
      episode: {:task, :review_id, :round},
      terminal: :parked,
      sites: [
        {ReviewGate, :push_gate, 1},
        {ReviewGate, :escalate_unpushed_head, 3},
        {ReviewGate, :escalate_pre_review_park, 2},
        {ReviewGate, :pushed_head, 1},
        {ReviewGate, :fallback_head, 1},
        # bd-bq8c8a: the same question one step earlier in the round — has the
        # remote moved PAST the head this round just reviewed, before a fix
        # round is allowed to build on it?
        {ReviewGate, :remote_advance, 1},
        {ReviewGate, :restart_on_remote_head, 3}
      ],
      anchors: [
        "push_gate",
        "escalate_unpushed_head",
        "pushed_head",
        ":head_not_pushed",
        "remote_advance"
      ],
      summary:
        "the head a round reviews (and the head a stamp/coverage row names) must be on the remote branch",
      policy_note:
        "bd-2jkrqu. One push attempt per round, then the terminal: a diverged or " <>
          "rejected push PARKS `:head_not_pushed` rather than force-pushing or " <>
          "reviewing a head the MR does not carry. Undeterminable push state (no " <>
          "`origin`, no worktree, git unavailable) fails OPEN — class B's posture, " <>
          "and the reason an ad-hoc checkout is not an incident. " <>
          "bd-bq8c8a added the pre-fix-round half: one fetch before the implementer " <>
          "is dispatched, and a remote that STRICTLY advanced skips the fix round " <>
          "and re-reviews the new head instead of producing an orphan commit that " <>
          "could only park here. It has no terminal of its own — every shape other " <>
          "than a clean fast-forward falls through to `push_gate/1` unchanged."
    }
  ]

  # ---------------------------------------------------------------------------
  # §2.2 `watchdog.ex` — the merge guard (W1–W19)
  # ---------------------------------------------------------------------------
  @watchdog_guards [
    %{
      id: :merge_coverage_decision,
      doc_ref: "W1",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :parked,
      # P4 (bd-df3zlo / #1736) split the decision in two: the workspace flag
      # picks which predicate is authoritative, `legacy_merge_decision/1` is
      # the `last_reviewed_sha` guard that routes to W2–W6, and
      # `apply_coverage_decision/3` maps §3.2's three answers onto the same
      # three outcomes (merge / W20's bounded wait / W6's re-review route).
      sites: [
        {Watchdog, :guarded_merge_decision, 1},
        {Watchdog, :legacy_merge_decision, 1},
        {Watchdog, :apply_coverage_decision, 3}
      ],
      anchors: [":stale_reviewed_sha", "coverage_enabled?"],
      summary:
        "merge-coverage decision: `decide/3` under `merge.coverage_enabled`, else the " <>
          "reviewed-SHA guard; routes to W2–W6 and W20"
    },
    %{
      id: :forge_head_lag_latch,
      doc_ref: "W2",
      class: :a,
      class_source: :doc,
      bound: {:polls, {:config, :head_lag_grace_polls}},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :parked,
      sites: [{Watchdog, :forge_head_lagging?, 1}],
      anchors: ["@head_lag_grace_polls"],
      summary: "wait out a PR resource that lags our own push"
    },
    %{
      id: :reconsider_recorded_stamp,
      doc_ref: "W3",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :parked,
      sites: [{Watchdog, :reconsider_stale_head, 3}],
      anchors: ["reconsider_stale_head"],
      summary: "re-read the recorded stamp instead of trusting the memo"
    },
    %{
      id: :live_head_recheck,
      doc_ref: "W4",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :parked,
      sites: [{Watchdog, :resolve_against_live_head, 3}],
      anchors: ["resolve_against_live_head"],
      summary: "re-read the live head before deciding"
    },
    %{
      id: :base_merge_only,
      doc_ref: "W5",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :parked,
      sites: [{Watchdog, :base_merge_only?, 3}],
      anchors: ["base_merge_only?"],
      summary: "content equality: a merge from base moved the head, not the diff"
    },
    %{
      id: :unreviewed_head_reroute,
      doc_ref: "W6",
      class: :a,
      class_source: :doc,
      bound: {:attempts, {:config, :default_max_auto_resumes}},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :failed_run,
      sites: [{Watchdog, :resolve_stale_reviewed_head, 3}],
      anchors: [":unreviewed_head", "@default_max_auto_resumes"],
      summary: "an unreviewed head fails the worker and buys a full re-review"
    },
    %{
      id: :merge_expected_sha,
      doc_ref: "W7",
      class: :a,
      class_source: :doc,
      bound: {:attempts, :unbounded},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :retries_forever,
      sites: [
        {Watchdog, :apply_guarded_merge, 2},
        {Watchdog, :escalate_merge_stall, 4}
      ],
      anchors: ["@default_merge_fail_notify_threshold", "merge_fail_count"],
      summary: "the forge's atomic expected_sha precondition on merge/2"
    },
    %{
      id: :fleet_push_latch_suspension,
      doc_ref: "W8",
      class: :a,
      class_source: :inferred,
      class_note:
        "§5.3 lists W1–W7 under class A; W8–W10 are the latch state that same " <>
          "decision reads and writes, so they are classed with it.",
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{Watchdog, :clear_reviewed_latch, 1}],
      anchors: ["clear_reviewed_latch"],
      summary: "the guard is suspended for pushes the fleet authored itself"
    },
    %{
      id: :reviewed_baseline_tracking,
      doc_ref: "W9",
      class: :a,
      class_source: :inferred,
      class_note: "Latch state behind the class-A decision; see W8.",
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{Watchdog, :track_reviewed_baseline, 2}],
      anchors: ["track_reviewed_baseline"],
      summary: "per-poll baseline tracking so the latch survives polls"
    },
    %{
      id: :via_review_gate_outcome_pin,
      doc_ref: "W10",
      class: :a,
      class_source: :inferred,
      class_note: "Latch state behind the class-A decision; see W8.",
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{Watchdog, :effective_outcome, 2}],
      anchors: ["effective_outcome", ":via_review_gate"],
      summary: "a gate-approved lane stays approved even if the forge shows none"
    },
    %{
      id: :ci_not_started_grace,
      doc_ref: "W11",
      class: :e,
      class_source: :doc,
      bound: {:polls, {:config, :not_started_grace_polls}},
      episode: {:task, :mr_ref, :poll},
      terminal: :proceeds,
      sites: [{Watchdog, :apply_outcome, 3}],
      anchors: ["@not_started_grace_polls"],
      summary: "grace polls for the zero-check-runs race before merging"
    },
    %{
      id: :poll_ceiling,
      doc_ref: "W12",
      class: :e,
      class_source: :doc,
      bound: {:polls, {:config, :default_max_polls_auto}},
      episode: {:task, :mr_ref},
      terminal: :failed_run,
      sites: [{Watchdog, :handle_review_timeout, 2}],
      anchors: ["@default_max_polls_auto", ":awaiting_review_timeout"],
      summary: "poll ceiling -> {:awaiting_review_timeout, N}"
    },
    %{
      id: :auto_resume_budget,
      doc_ref: "W13",
      class: :e,
      class_source: :doc,
      bound: {:attempts, {:config, :default_max_auto_resumes}},
      episode: {:task, :mr_ref},
      terminal: :escalated_once,
      sites: [
        {Watchdog, :attempt_auto_resume, 1},
        {Watchdog, :escalate_auto_resume_give_up, 4},
        {Watchdog, :escalate_watchdog, 1}
      ],
      anchors: ["@default_max_auto_resumes"],
      summary: "bounded auto-resume, then one escalation and stop"
    },
    %{
      id: :resume_deferral_budget,
      doc_ref: "W14",
      class: :e,
      class_source: :doc,
      bound: {:deferrals, {:config, :default_max_resume_deferrals}},
      episode: {:task, :mr_ref},
      # bd-985tkl: class E's terminal is "parked and still watched", and the
      # park row is what claims the one page (invariant I3). Both arms of the
      # terminal — the deferral budget running out, and a blocker that is
      # already dead — go through `park_and_escalate_resume_block/3`.
      terminal: :parked,
      sites: [
        {Watchdog, :handle_resume_error, 3},
        {Watchdog, :park_and_escalate_resume_block, 3}
      ],
      anchors: [
        "@default_max_resume_deferrals",
        ":resume_blocked",
        ":resume_blocker_vanished"
      ],
      summary:
        "a resume refused by the task's own fix pass is deferred until that pass finishes, " <>
          "then parked with one page — never retried forever and never dropped"
    },
    %{
      id: :nonauthor_approval_park,
      doc_ref: "W15",
      class: :e,
      class_source: :doc,
      bound: {:escalations, 1},
      episode: {:task, :mr_ref},
      terminal: :parked,
      sites: [{Watchdog, :handle_nonauthor_approval, 2}],
      anchors: ["handle_nonauthor_approval"],
      summary: "a forge that needs a non-author approver parks instead of failing"
    },
    %{
      id: :block_escalation_debounce,
      doc_ref: "W16",
      class: :e,
      class_source: :doc,
      bound: {:escalations, 1},
      episode: {:task, :mr_ref, :block_reason},
      terminal: :escalated_once,
      sites: [
        {Watchdog, :debounce_escalate_block, 2},
        {Watchdog, :maybe_escalate_merge_block, 2},
        {Watchdog, :do_maybe_escalate_merge_block, 2},
        {Watchdog, :route_merge_block, 2}
      ],
      anchors: ["debounce_escalate_block"],
      summary: "one page per block reason, not one per poll"
    },
    %{
      id: :auto_resolve_attempts,
      doc_ref: "W17",
      class: :e,
      class_source: :doc,
      bound: {:attempts, {:config, :default_max_auto_resolve_attempts}},
      episode: {:task, :mr_ref, :block_reason},
      terminal: :parked,
      sites: [
        {Watchdog, :maybe_escalate_unresolved, 2},
        {Watchdog, :escalate_unresolved_block, 2},
        {Watchdog, :escalate_merge_unresolved, 5},
        {Watchdog, :resolve_behind_base, 1}
      ],
      anchors: ["@default_max_auto_resolve_attempts"],
      summary: "bounded behind_base / ci_failed auto-resolve, then watch only"
    },
    %{
      id: :conflict_resolution_attempts,
      doc_ref: "W18",
      class: :e,
      class_source: :doc,
      bound: {:attempts, {:config, :default_max_conflict_attempts}},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :escalated_once,
      sites: [
        {Watchdog, :drive_conflict_resolution, 1},
        {Watchdog, :escalate_conflict_exhausted, 2}
      ],
      anchors: ["@default_max_conflict_attempts"],
      summary: "bounded conflict-resolver spawns, then one escalation"
    },
    %{
      id: :park_heartbeat,
      doc_ref: "W19",
      class: :e,
      class_source: :doc,
      bound: {:polls, {:config, :default_park_heartbeat_polls}},
      episode: {:task, :mr_ref, :block_reason},
      terminal: :parked,
      sites: [{Watchdog, :park_heartbeat_due?, 1}],
      anchors: ["@default_park_heartbeat_polls"],
      summary: "one heartbeat re-page for a long park, not silence and not a storm"
    },
    %{
      id: :orphaned_merge_retry,
      doc_ref: "W21",
      class: :e,
      class_source: :inferred,
      class_note:
        "bd-a370ak / #2002. Not in §5.3's table. It is remediation of a stranded approved " <>
          "merge — W12's terminal made real for the case where the worker is already gone — " <>
          "and it has class E's shape: fail open, bounded retries, one escalation. The merge " <>
          "decision it runs is W1–W5 and the zero-net-diff guard unchanged; only the " <>
          "retry-and-give-up wrapped around it is new.",
      bound: {:retries, {:config, :retry_transient_failure_limit}},
      episode: {:task, :mr_ref},
      terminal: :escalated_once,
      sites: [
        {Watchdog, :detached_outcome, 3},
        {Watchdog, :detached_attempt_merge, 2},
        {Watchdog, :handle_retry_merge_failure, 2},
        {Watchdog, :retry_still_owed, 1},
        {Watchdog, :detached_wait, 2},
        {Watchdog, :detached_ci_red, 1},
        {Watchdog, :notify_ci_red_once, 1},
        {Watchdog, :give_up_retry, 2}
      ],
      anchors: [
        "@retry_transient_failure_limit",
        "@default_retry_max_wait_ms",
        "wait_exhausted",
        "merge_fail_notify_threshold",
        "orphaned_merge_abandoned",
        "mark_escalated",
        "note_block"
      ],
      summary:
        "a worker-less retry of an approved merge whose worker exited: waits out transient " <>
          "blockers (red CI included, noticed once), merges through W1–W5, else pages once " <>
          "and latches the stamp escalated"
    }
  ]

  # ---------------------------------------------------------------------------
  # §2.3 `merge_queue.ex` — the out-of-process queue (M1–M7)
  # ---------------------------------------------------------------------------
  @merge_queue_guards [
    %{
      id: :queue_merge_refusal,
      doc_ref: "M1",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :parked,
      sites: [
        {MergeQueue, :merge_guarded, 2},
        {MergeQueue, :legacy_merge_decision, 3},
        {MergeQueue, :apply_legacy_decision, 3},
        {MergeQueue, :apply_coverage_decision, 4}
      ],
      anchors: [":stale_reviewed_sha", "coverage_enabled?"],
      summary:
        "the queue's merge refusal: `decide/3` under `merge.coverage_enabled`, else the " <>
          "reviewed-SHA guard plus W5's content check (P7) — none of W2–W4/W6's recovery"
    },
    %{
      id: :coverage_unknown_wait,
      doc_ref: "W20",
      class: :a,
      class_source: :inferred,
      class_note:
        "§5.3 lists W1–W7 under class A; this is the wait W1's own `{:unknown, _}` " <>
          "answer resolves to under P4, so it is classed with it.",
      bound: {:polls, {:config, :coverage_unknown_grace_polls}},
      episode: {:task, :mr_ref, :head_sha},
      terminal: :escalated_once,
      sites: [{Watchdog, :wait_for_coverage, 3}, {Watchdog, :restore_poll_ceiling, 1}],
      anchors: ["@coverage_unknown_grace_polls", ":coverage_unknown", "coverage_park_poll"],
      summary:
        "an `unknown` coverage answer waits, bounded, then parks and pages once — with the " <>
          "`auto_merge` poll ceiling lifted so the park cannot decay into a re-review"
    },
    %{
      id: :queue_baseline_precedence,
      doc_ref: "M2",
      class: :a,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{MergeQueue, :item_reviewed_sha, 1}],
      anchors: ["item_reviewed_sha"],
      summary: "recorded stamp takes precedence over the latch"
    },
    %{
      id: :queue_stale_sha_retry,
      doc_ref: "M3",
      class: :a,
      class_source: :doc,
      bound: {:attempts, :unbounded},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :retries_forever,
      sites: [{MergeQueue, :try_merge, 2}],
      anchors: ["try_merge"],
      summary: "a refused merge leaves the item's status untouched, so it retries every tick"
    },
    %{
      id: :queue_latch_suspension,
      doc_ref: "M4",
      class: :a,
      class_source: :inferred,
      class_note: "The queue's hand-maintained mirror of W8; classed with it.",
      bound: {:evaluations, 1},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{MergeQueue, :clear_reviewed_latch, 1}],
      anchors: ["clear_reviewed_latch"],
      summary: "the queue suspends the guard for its own rebase/resolver pushes"
    },
    %{
      id: :queue_baseline_tracking,
      doc_ref: "M5",
      class: :a,
      class_source: :inferred,
      class_note: "The queue's hand-maintained mirror of W9; classed with it.",
      bound: {:evaluations, 1},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{MergeQueue, :track_reviewed_baseline, 2}],
      anchors: ["track_reviewed_baseline"],
      summary: "per-poll baseline tracking, mirrored from the Watchdog by hand"
    },
    %{
      id: :queue_suspension_lift,
      doc_ref: "M6",
      class: :a,
      class_source: :inferred,
      class_note: "The queue's hand-maintained mirror of the Watchdog's lift condition.",
      bound: {:evaluations, 1},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :proceeds,
      sites: [{MergeQueue, :latch_suspended?, 2}],
      anchors: ["latch_suspended?"],
      summary: "when the suspension lifts again"
    },
    %{
      id: :queue_item_status_shortcircuit,
      doc_ref: "M7",
      class: :e,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:item, :status},
      terminal: :parked,
      sites: [{MergeQueue, :poll_item, 2}],
      anchors: ["poll_item"],
      summary: "terminal items are not re-polled"
    }
  ]

  # ---------------------------------------------------------------------------
  # §2.4 `worker.ex` — the commit gate and the fix-round dispatcher (C1–C4)
  # ---------------------------------------------------------------------------
  @worker_guards [
    %{
      id: :worker_commit_gate,
      doc_ref: "C1",
      class: :d,
      class_source: :doc,
      bound: {:retries, 1},
      episode: {:task, :attempt},
      terminal: :failed_run_by_design,
      sites: [
        {Worker, :commit_gate, 1},
        {Worker, :park_commit_gate, 3},
        {Worker, :escalate_commit_gate, 3}
      ],
      anchors: ["commit_gate", ":secret_in_commit"],
      summary: "a worker cannot print `arb done` over uncommitted or absent work",
      policy_note:
        "§6.2 keeps this guard as-is: it gates commit hygiene and secrets, not " <>
          "review coverage. A spent nudge budget means the work really was never " <>
          "committed, so `Run.status = :failed` is the honest record, not an I2 " <>
          "violation. Git errors still fail open."
    },
    %{
      id: :queue_coverage_unknown_wait,
      doc_ref: "M8",
      class: :a,
      class_source: :inferred,
      class_note: "The queue's mirror of W20; classed with it.",
      bound: {:polls, {:config, :coverage_unknown_grace_ticks}},
      episode: {:item, :mr_ref, :head_sha},
      terminal: :escalated_once,
      sites: [
        {MergeQueue, :wait_for_coverage, 4},
        {MergeQueue, :safe_notify_coverage_block, 2}
      ],
      anchors: ["@coverage_unknown_grace_ticks", ":coverage_unknown"],
      summary: "an `unknown` coverage answer waits, bounded, then parks and pages once"
    },
    %{
      id: :rejection_parking,
      doc_ref: "C2",
      class: :d,
      class_source: :inferred,
      class_note:
        "§5.3 lists C1 and C3 under class D. C2 is the same module's terminal " <>
          "handling for those outcomes, so it is classed with them; it is also the " <>
          "single place a class-C ReviewGate outcome becomes a failed run.",
      bound: {:evaluations, 1},
      episode: {:task, :review_id},
      terminal: :failed_run,
      sites: [
        {Worker, :park_rejected, 4},
        {Worker, :fail_reason_for, 1},
        {Worker, :escalate_review_gate, 3},
        {Worker, :park_review_gate, 3},
        {Worker, :escalate_review_park, 3},
        {Worker, :fail_now, 2}
      ],
      anchors: [":review_gate_inconclusive", "fail_reason_for", ":review_parked"],
      summary: "the single point a gate outcome becomes a failed run — or, since P9, a park",
      policy_note:
        "P9 (bd-9zuvbh) split this. `park_rejected/4` now takes a park reason: " <>
          "with one it writes `Run.status = :review_parked`, stamps " <>
          "`issues.review_park_reason` and pages once via `park_review_gate/3`; " <>
          "without one it is the pre-P9 path. Every class-C terminal passes a " <>
          "reason, so the `:failed_run` recorded here is now reachable only from a " <>
          "genuine REQUEST_CHANGES — see G14."
    },
    %{
      id: :fix_round_budget,
      doc_ref: "C3",
      class: :d,
      class_source: :doc,
      bound: {:rounds, {:config, :resolve_max_fix_rounds}},
      episode: {:task, :review_id, :round},
      terminal: :escalated_once,
      sites: [
        {Worker, :maybe_dispatch_fix_round, 3},
        {Worker, :give_up_fix_round, 4}
      ],
      anchors: ["resolve_max_fix_rounds", ":not_converging"],
      summary: "bounded fix rounds plus an identical-findings digest — §5's template"
    },
    %{
      id: :awaiting_review_timeout_status,
      doc_ref: "C4",
      class: :d,
      class_source: :inferred,
      class_note:
        "Not classed in §5.3. It is the terminal-status mapping the whole policy " <>
          "points at (I2's `review_not_started` shape), and it lives beside C1–C3, " <>
          "so it is classed with them.",
      bound: {:evaluations, 1},
      episode: {:task, :mr_ref},
      terminal: :parked,
      sites: [{Worker, :run_status, 1}],
      anchors: [":awaiting_review_timeout", ":review_not_started"],
      summary: "a resumable timeout is a terminal non-failure, not :failed"
    }
  ]

  # ---------------------------------------------------------------------------
  # §2.5 ReviewPatrol (R1–R6) and PRPatrol (P1–P7)
  # ---------------------------------------------------------------------------
  @patrol_guards [
    %{
      id: :head_advance_cursor,
      doc_ref: "R1",
      class: :f,
      class_source: :inferred,
      class_note:
        "§5.3's class F is R2–R6 and P1–P7; R1 is the same patrol's engagement " <>
          "cursor and gates the same filing decision, so it is classed with them. " <>
          "P12 demotes the column it shares with the merge guard.",
      bound: {:evaluations, 1},
      episode: {:pr, :head_sha},
      terminal: :proceeds,
      sites: [{ReviewPatrol, :maybe_record_head_sha, 2}],
      anchors: ["maybe_record_head_sha", "last_reviewed_sha"],
      summary: "head-advance detection, sharing last_reviewed_sha with the merge guard"
    },
    %{
      id: :ci_settle_gate,
      doc_ref: "R2",
      class: :f,
      class_source: :doc,
      bound: {:polls, :unbounded},
      episode: {:pr, :head_sha},
      terminal: :retries_forever,
      sites: [{ReviewPatrol, :ci_settled?, 1}],
      anchors: ["ci_settled?"],
      summary: "do not review mid-pipeline — but a never-settling pipeline defers forever"
    },
    %{
      id: :review_debounce,
      doc_ref: "R3",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :head_sha},
      terminal: :skipped,
      sites: [{ReviewPatrol, :debounced?, 2}],
      anchors: ["@default_debounce_ms"],
      summary: "debounce window against review spam on rapid pushes"
    },
    %{
      id: :per_pr_review_cap,
      doc_ref: "R4",
      class: :f,
      class_source: :doc,
      bound: {:reviews, {:config, :default_max_reviews}},
      episode: {:pr},
      terminal: :frozen,
      sites: [
        {ReviewPatrol, :review_capped?, 2},
        {ReviewPatrol, :handle_review_cap, 2},
        {ReviewPatrol, :escalate_review_cap, 2}
      ],
      anchors: ["@default_max_reviews"],
      summary: "bounded review spend on one PR, then frozen behind one escalation"
    },
    %{
      id: :review_cap_escalation_claim,
      doc_ref: "R5",
      class: :f,
      class_source: :doc,
      bound: {:escalations, 1},
      episode: {:pr, :cap},
      terminal: :escalated_once,
      sites: [{ReviewPatrol, :claim_review_cap_escalation, 1}],
      anchors: ["claim_review_cap_escalation"],
      summary: "I3's reference implementation: an atomic one-per-episode claim"
    },
    %{
      id: :relevance_gate,
      doc_ref: "R6",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :head_sha},
      terminal: :skipped,
      sites: [{ReviewPatrol, :gate_on_relevance, 5}],
      anchors: ["gate_on_relevance"],
      summary: "do not re-review commits irrelevant to the thread"
    },
    %{
      id: :dispatch_attempt_bound,
      doc_ref: "P1",
      class: :f,
      class_source: :doc,
      bound: {:attempts, {:config, :max_dispatch_attempts}},
      episode: {:pr},
      terminal: :given_up,
      sites: [{PRPatrol, :record_dispatch_failure, 4}],
      anchors: ["@max_dispatch_attempts"],
      summary: "§5's reference implementation of class F: bounded, one final page, given_up"
    },
    %{
      id: :give_up_block,
      doc_ref: "P2",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr},
      terminal: :given_up,
      sites: [{PRPatrol, :backing_off?, 2}],
      anchors: ["backing_off?"],
      summary: "a given-up PR does not resume after backoff"
    },
    %{
      id: :re_escalation_throttle,
      doc_ref: "P3",
      class: :f,
      class_source: :doc,
      bound: {:escalations, 1},
      episode: {:pr, :hour},
      terminal: :escalated_once,
      sites: [{PRPatrol, :escalate_dispatch_failure, 4}],
      anchors: ["@max_backoff_ms"],
      summary: "at most one re-page an hour, plus one unconditional final"
    },
    %{
      id: :follow_up_dedupe,
      doc_ref: "P4",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :thread},
      terminal: :skipped,
      sites: [{PRPatrol, :deduped?, 2}],
      anchors: ["deduped?"],
      summary: "one follow-up per thread"
    },
    %{
      id: :zombie_idle_unblock,
      doc_ref: "P5",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :thread},
      terminal: :proceeds,
      sites: [{PRPatrol, :still_blocking?, 1}],
      anchors: ["still_blocking?"],
      summary: "a crashed dispatch must not blackhole every future trigger"
    },
    %{
      id: :answered_thread_rejection,
      doc_ref: "P6",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :thread},
      terminal: :skipped,
      sites: [{PRPatrol, :reject_answered_threads, 2}],
      anchors: ["reject_answered_threads"],
      summary: "do not re-file a thread we already answered"
    },
    %{
      id: :author_allowlist,
      doc_ref: "P7",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :author},
      terminal: :skipped,
      sites: [{PRPatrol, :author_allowed?, 2}],
      anchors: ["author_allowed?"],
      summary: "do not patrol third-party PRs"
    },
    %{
      id: :review_gate_branch_hold,
      doc_ref: "P8",
      class: :f,
      class_source: :doc,
      bound: {:evaluations, 1},
      episode: {:pr, :tick},
      terminal: :skipped,
      sites: [{PRPatrol, :review_gate_holds?, 2}],
      anchors: ["review_gate_holds?", "GateActivity"],
      summary:
        "bd-bq8c8a: while the ReviewGate owns a branch, nothing else may commit to it — " <>
          "fails CLOSED on an undeterminable read (§5.2: a guard on filing)",
      policy_note:
        "One evaluation per PR per tick, and the terminal is a SKIP, not a give-up: the " <>
          "threads stay unresolved and the first tick after the gate converges files the " <>
          "follow-up this one declined. So the fail-closed posture costs one ~60s interval " <>
          "and consumes nothing, while failing open re-runs the reported collision. " <>
          "Residual window (accepted): G18's companion `remote_advance/1` fetches before the " <>
          "gate DISPATCHES its implementer, so a push landing during an already-running fix " <>
          "round still degrades to G18's `:head_not_pushed` park — this hold is what closes " <>
          "that window for the patrol as the pusher."
    }
  ]

  @guards @review_gate_guards ++
            @watchdog_guards ++ @merge_queue_guards ++ @worker_guards ++ @patrol_guards

  # Rows that violate §5's policy **today**. Each names the wave-1/wave-2 phase
  # from §7 that removes it. P8 records them; it does not fix them. The list may
  # only shrink — `guard_registry_test.exs` freezes the id set.
  @known_violations [
    %{
      id: :queue_stale_sha_retry,
      violation: :unbounded_retry,
      removed_by: :p6,
      note:
        "§2.3 M3: a refused merge leaves the queue item's status untouched, so the " <>
          "same merge is re-attempted every tick forever. This is the 303-retry " <>
          "shape. P6 gives it class A's bound plus a terminal park."
    },
    %{
      id: :merge_expected_sha,
      violation: :unbounded_retry,
      removed_by: :p6,
      note:
        "§2.3/§5.1 W7: `merge_fail_count` gates only the page; the merge call is " <>
          "re-issued every poll and the paging branch lifts `max_polls` to " <>
          ":infinity. P6 turns the same counter into a terminal bound at N = 5."
    },
    %{
      id: :unreviewed_head_reroute,
      violation: :reaches_worker_fail,
      removed_by: :p4,
      note:
        "§2.2 W6: a class-A guard calls `Worker.fail/2` with {:unreviewed_head, " <>
          "head} to buy a re-review. P4's read-path flip decides from coverage " <>
          "instead, and its AC is that no {:unreviewed_head, _} appears in the " <>
          "journal."
    },
    %{
      id: :unreviewed_head_reroute,
      violation: :fails_run,
      removed_by: :p4,
      note:
        "The same W6 path records Run.status = :failed while it buys the " <>
          "re-review, so it breaks I2 as well as class A's fail-closed-with-a-park " <>
          "rule. P4 removes both together."
    },
    %{
      id: :round_budget,
      violation: :fails_run,
      removed_by: :p10,
      note:
        "P9 removed half of this: a verdict guard that refused an APPROVE and hit " <>
          "the cap now parks. What is left is a reviewer that really said " <>
          "REQUEST_CHANGES for every round — P9's AC1 states explicitly that this " <>
          "still behaves as today, so §5.3's class-D park for G14 moves to P10's " <>
          "class audit rather than being claimed here."
    },
    %{
      id: :rejection_parking,
      violation: :fails_run,
      removed_by: :p10,
      note:
        "P9 met its AC here: no ReviewGate outcome with an approving or no-verdict " <>
          "result reaches Run.status = :failed any more — `park_rejected/4` writes " <>
          "`:review_parked` for every class-C terminal. The row keeps the entry " <>
          "because the one arm P9 deliberately left (a genuine REQUEST_CHANGES at " <>
          "G14's round cap) still routes through this same conversion point."
    },
    %{
      id: :poll_ceiling,
      violation: :fails_run,
      removed_by: :p10,
      note:
        "§2.2 W12 fails the worker at the ceiling; C4 already maps the reason to " <>
          ":review_not_started, so the run is recorded as a terminal non-failure. " <>
          "P10's class-E audit removes the `Worker.fail/2` hop itself."
    },
    %{
      id: :ci_settle_gate,
      violation: :unbounded_retry,
      removed_by: :p10,
      note: "§2.5 R2 has no bound: a never-settling pipeline defers every tick. P10 bounds it."
    }
  ]

  @doc "Every guard row, in §2 inventory order."
  @spec guards() :: [row()]
  def guards, do: @guards

  @doc "Every registry id."
  @spec ids() :: [atom()]
  def ids, do: Enum.map(@guards, & &1.id)

  @doc "Every §2 inventory id (like `G1` or `W7`) that has a row."
  @spec doc_refs() :: [String.t()]
  def doc_refs, do: Enum.map(@guards, & &1.doc_ref)

  @doc """
  The row for `id`.

  Raises rather than returning `nil`: like `ReviewGate.verdict_guard_spec/2`, a
  guard that half-exists is worse than one that does not compile.
  """
  @spec fetch!(atom()) :: row()
  def fetch!(id) do
    case Enum.find(@guards, &(&1.id == id)) do
      nil -> raise ArgumentError, "no guard registry row for #{inspect(id)}"
      row -> row
    end
  end

  @doc "The row carrying §2 inventory id `doc_ref`, or `nil`."
  @spec by_doc_ref(String.t()) :: row() | nil
  def by_doc_ref(doc_ref), do: Enum.find(@guards, &(&1.doc_ref == doc_ref))

  @doc "Rows in `class`."
  @spec by_class(class()) :: [row()]
  def by_class(class), do: Enum.filter(@guards, &(&1.class == class))

  @doc "Rows with at least one site in `module`."
  @spec by_module(module()) :: [row()]
  def by_module(module) do
    Enum.filter(@guards, fn row -> Enum.any?(row.sites, fn {mod, _, _} -> mod == module end) end)
  end

  @doc "The guard classes, `:a`–`:f`."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "§5.3's policy for each class."
  @spec class_policies() :: %{class() => map()}
  def class_policies, do: @class_policies

  @doc "The closed set of terminal states a row may declare."
  @spec terminals() :: [terminal()]
  def terminals, do: @terminals

  @doc "The closed set of bound units a row may declare."
  @spec bound_units() :: [bound_unit()]
  def bound_units, do: @bound_units

  @doc """
  The modules the freeze covers, with each one's source path and the scan
  signals its refusals are visible through.
  """
  @spec control_plane() :: [%{module: module(), path: String.t(), signals: [atom()]}]
  def control_plane, do: @control_plane

  @doc "Rows that violate §5's policy today, each naming the phase that removes it."
  @spec known_violations() :: [
          %{id: atom(), violation: atom(), removed_by: atom(), note: String.t()}
        ]
  def known_violations, do: @known_violations

  @doc "The violation entries recorded against `id` (empty when the row conforms)."
  @spec violations(atom()) :: [map()]
  def violations(id), do: Enum.filter(@known_violations, &(&1.id == id))

  @doc "True when `id` has a recorded violation of `kind`."
  @spec violation?(atom(), atom()) :: boolean()
  def violation?(id, kind) do
    Enum.any?(@known_violations, &(&1.id == id and &1.violation == kind))
  end

  @doc """
  True when `bound` names a finite number of attempts.

  `{unit, {:config, name}}` is finite by construction: the value comes from a
  module attribute or resolver whose name is anchored on the row.
  """
  @spec finite_bound?(bound()) :: boolean()
  def finite_bound?({unit, n}) when unit in @bound_units and is_integer(n) and n > 0, do: true
  def finite_bound?({unit, {:config, name}}) when unit in @bound_units and is_atom(name), do: true
  def finite_bound?(_), do: false
end
