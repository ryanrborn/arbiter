# Dialyzer warning filters for the whole umbrella (see `dialyzer/0` in
# mix.exs, which points every app here).
#
# `list_unused_filters: true` is set alongside it, so a filter that stops
# matching FAILS the run rather than lingering. That is deliberate: a
# suppression file nobody prunes is how a real warning eventually gets
# masked by a stale entry someone added for an unrelated reason.
#
# Entries may be:
#
#     {"lib/arbiter/some_module.ex"}                      # whole file
#     {"lib/arbiter/some_module.ex", :unknown_function}   # file + warning type
#     {"lib/arbiter/some_module.ex", :call, 42}           # file + type + line
#     ~r/regex against the formatted warning/
#
# Add one only with a comment saying which warning it silences and why the
# code is correct as written.
#
# ── Why these are {file, type} pairs and not {file, type, line} ────────────
#
# Line-pinned filters would be tighter, but every entry below sits in a file
# that fleet workers edit constantly (worker.ex is ~4.5k lines, dispatch.ex
# ~2.2k). A line-pinned baseline turns any insertion above a filtered site
# into an "Unnecessary Skip" and fails CI on a PR that changed nothing
# related. File+type keeps the baseline stable under line drift while still
# failing on a NEW warning class in the same file — the trade the credo
# baseline in this branch made too (per-site `disable-for-next-line`, but
# thresholds left at the tool's own defaults).
#
# Everything here was triaged individually during bd-4x2yhq's first pass.
# The genuine bugs that pass turned up were FIXED, not filtered — see the
# preceding commits: two closed map specs (CoordinatorNotifier.snapshot/0,
# MCP.Scope.mint_worker/3), Watchdog.parked_on/1's missing
# `:ci_failed_external`, Quota.Overage.windowed_spend/2's over-narrow
# params, Tasks.Claim.claim_result's missing tuple errors, and a bogus
# `allow_nonexistent_atoms?` option that typed ArbiterCli.Output.
# extract_mode/1 as `none()`. That is 33 of the original 94 warnings.
[
  # ── 1. Defensive catch-all clauses (`pattern_match_cov`) ──────────────────
  #
  # `_other -> ...` / `_ -> ...` fallbacks placed after clauses that, for the
  # types dialyzer can currently see, already cover the domain. They are not
  # dead code in any meaningful sense: the values reaching them come from
  # tracker/merger JSON, agent stdout, Ash resources and LiveView assigns,
  # i.e. from outside the analysed boundary, where a shape dialyzer proved
  # impossible today becomes possible the moment an upstream API adds an enum
  # value. Deleting the clause converts that into a FunctionClauseError inside
  # a GenServer — for the Watchdog and the patrols, a crash loop on live
  # workers. The clause stays; the warning does not.
  {"lib/arbiter/agents/gemini.ex", :pattern_match_cov},
  {"lib/arbiter/agents/gemini/stream.ex", :pattern_match_cov},
  {"lib/arbiter/agents/security_policy.ex", :pattern_match_cov},
  {"lib/arbiter/board/snapshot.ex", :pattern_match_cov},
  {"lib/arbiter/reviews/external_review.ex", :pattern_match_cov},
  {"lib/arbiter/skills/selection.ex", :pattern_match_cov},
  {"lib/arbiter/tasks/claim.ex", :pattern_match_cov},
  {"lib/arbiter/worker.ex", :pattern_match_cov},
  {"lib/arbiter/worker/claude_session.ex", :pattern_match_cov},
  {"lib/arbiter/worker/review_gate.ex", :pattern_match_cov},
  {"lib/arbiter/worker/watchdog.ex", :pattern_match_cov},
  {"lib/arbiter/workflows/machine.ex", :pattern_match_cov},
  {"lib/arbiter/workflows/pr_patrol.ex", :pattern_match_cov},
  {"lib/arbiter/workflows/review_patrol.ex", :pattern_match_cov},
  {"lib/arbiter_cli/client.ex", :pattern_match_cov},
  {"lib/arbiter_cli/cmd/loop.ex", :pattern_match_cov},
  {"lib/arbiter_web/live/board_live.ex", :pattern_match_cov},
  {"lib/arbiter_web/live/loop_proposal_index_live.ex", :pattern_match_cov},
  {"lib/arbiter_web/live/worker_detail_live.ex", :pattern_match_cov},
  {"lib/arbiter_web/live/worker_index_live.ex", :pattern_match_cov},

  # ── 2. Defensive error branches (`pattern_match`) ─────────────────────────
  #
  # `{:error, reason} -> ...` (or a narrower error atom) after a callee whose
  # success typing has only the happy arm today. Same reasoning as group 1,
  # with one addition specific to the controllers: dropping the branch means
  # an unexpected error propagates as a 500 instead of the mapped 4xx, and
  # `Autopilot.pause/0` / `resume/0` are GenServer calls whose contract is a
  # one-line change away from gaining an error arm.
  #
  #   * agents/preflight.ex, arbiter_cli/version.ex — not defensive clauses
  #     at all: dialyzer resolves a build-time predicate to a constant
  #     (`function_exported?/3` against a module it has already analysed;
  #     `@git_dirty`, which is baked in by `git status --porcelain` when the
  #     module compiles) and calls the other branch of the `if` dead. Which
  #     branch is dead depends on the machine doing the build.
  #   * quota/refresh_probe.ex — `if env == []`, where `env` is
  #     `ConfigDir.env() ++ [{"ANTHROPIC_BASE_URL", base_url}]` and so is
  #     never empty. Kept as a guard against the tail being made optional.
  #   * worker/review_gate.ex, workflows/conductor.ex — a bare `:no_verdict`
  #     atom clause beside the `{:no_verdict, reason}` tuple one, and a
  #     `load_member_issues([])` clause. Both are cheap total-function
  #     hygiene on a private helper.
  {"lib/arbiter/agents/preflight.ex", :pattern_match},
  {"lib/arbiter/mcp/tools.ex", :pattern_match},
  {"lib/arbiter/mcp/tools/loop_pending.ex", :pattern_match},
  {"lib/arbiter/quota/refresh_probe.ex", :pattern_match},
  {"lib/arbiter/worker/driver.ex", :pattern_match},
  {"lib/arbiter/worker/review_gate.ex", :pattern_match},
  {"lib/arbiter/workflows/conductor.ex", :pattern_match},
  {"lib/arbiter_cli/version.ex", :pattern_match},
  {"lib/arbiter_web/controllers/api/loop_controller.ex", :pattern_match},
  {"lib/arbiter_web/controllers/api/scheduler_controller.ex", :pattern_match},
  {"lib/mix/tasks/arbiter.loop.analyze.ex", :pattern_match},

  # ── 3. Defensive nil / type guards (`guard_fail`, `neg_guard_fail`) ───────
  #
  # `when x === nil`, `when not is_binary(x)`, `when is_integer(id)` on a
  # value every current caller supplies non-nil and of one type. These are
  # the guard-clause form of group 1 and protect the same boundaries:
  #
  #   * trackers/gitlab.ex — `resolve_user_id/2`'s documented "or a numeric
  #     id, passed through" clause. Every caller happens to hold a binary
  #     today; the pass-through is part of the helper's contract.
  #   * worker.ex, worker/dispatch.ex — nil-checks on `meta` maps and branch
  #     names that Ash and the mergers type as non-nil but that arrive from
  #     persisted task rows, where a NULL column is one migration away.
  #   * loop/analysis.ex, arbiter_cli/cmd/self_update.ex — the same shape on
  #     a report map and a version string.
  {"lib/arbiter/loop/analysis.ex", :guard_fail},
  {"lib/arbiter/trackers/gitlab.ex", :guard_fail},
  {"lib/arbiter/worker.ex", :guard_fail},
  {"lib/arbiter/worker/dispatch.ex", :guard_fail},
  {"lib/arbiter/worker/dispatch.ex", :neg_guard_fail},
  {"lib/arbiter_cli/cmd/self_update.ex", :guard_fail},

  # ── 4. MapSet opaqueness (`contract_with_opaque`, `call_without_opaque`) ──
  #
  # A long-standing dialyzer limitation, not a defect in this code. `MapSet.t`
  # is opaque, but dialyzer sees through to the concrete `{:set, ...}` /
  # `%{_ => []}` internal representation whenever it can constant-fold a
  # `MapSet.new/0,1` in the same analysis pass. It then reports the resulting
  # concrete type as "violating" the very opaque type it just unwrapped. Every
  # site here builds a MapSet and passes it straight to another MapSet
  # function — `MapSet.union/2`, `MapSet.disjoint?/2` — which is exactly the
  # supported use.
  {"lib/arbiter/board/file_scope.ex", :contract_with_opaque},
  {"lib/arbiter/board/snapshot.ex", :call_without_opaque},
  {"lib/arbiter/workflows/review_patrol.ex", :call_without_opaque},

  # ── 5. `pattern_match` fallout from the `:exact_compare` fixes ────────────
  #
  # OTP 28 added an `:exact_compare` warning class that dialyxir 1.4.7 can
  # neither format ("Unknown warning: :exact_compare / Please file a bug") nor
  # filter — `Dialyxir.Formatter.filter_warning/3` only consults the ignore
  # file for warning types it knows, so no entry here can silence one. Both
  # sites were therefore rewritten in source rather than suppressed
  # (refresh_probe.ex `Enum.empty?(env)`, pr_patrol.ex `meta: nil` in the
  # clause head). pr_patrol's rewrite moves the nil check into a clause the
  # analysed types say is unreachable, i.e. group 1 again.
  {"lib/arbiter/workflows/pr_patrol.ex", :pattern_match}
]
