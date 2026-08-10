defmodule Arbiter.ReviewGate.Round do
  @moduledoc """
  A durable, structured outcome for a single `Arbiter.Worker.ReviewGate` pass
  (bd-aqyjuc / #1011 gap G2).

  Before this resource existed, a ReviewGate round's outcome survived nowhere
  but reviewer transcript prose (a `VERDICT: APPROVE`/`REQUEST_CHANGES` line
  buried in a 1,000+ line run) and the authoring run's terminal
  `failure_reason` — which only distinguishes the FINAL round from all others,
  and only on failure. A task rejected in round 1 and approved in round 2
  recorded as `main | completed | failure_reason NULL`; the round-1 rejection
  was invisible without an LLM re-reading the transcript.

  One row is inserted per reviewer pass (when its verdict is parsed) and per
  implementer pass (when its revise response is captured) — at the point
  `Arbiter.Worker.ReviewGate` already holds everything in hand, so the write
  is a pure side effect with no additional parsing. Rows for malformed/no-verdict
  passes (re-prompted, retried) are deliberately NOT written — only a pass that
  reaches a genuine, actionable outcome (an APPROVE, a REQUEST_CHANGES with real
  findings, or a completed implementer revision) gets a row.

  ## Fields

    * `task_id`        — the task under review (never carries the `#review`/
                          `#implN` synthetic suffixes ReviewGate uses internally
                          for its own worker ids).
    * `run_id`         — best-effort FK to the `Arbiter.Workers.Run` row for
                          this specific pass (the synthetic reviewer/implementer
                          worker, not the author's run). Nil if it couldn't be
                          resolved.
    * `round`          — 1-indexed revise-and-rediscuss round this pass belongs to.
    * `role`           — `:review` (a reviewer pass) or `:impl` (an implementer
                          revise pass).
    * `verdict`        — `:approve` or `:request_changes` for a `:review` row;
                          always nil for `:impl` (implementers don't issue verdicts).
    * `findings`        — the reviewer's findings text (from the `VERDICT:` line
                          onward) for a `:review` row, or the implementer's raw
                          revise-response transcript for an `:impl` row.
    * `finding_count`   — best-effort count of enumerated findings (list-item
                          lines) in `findings`. Nil for `:impl` rows.
    * `reviewer_model`  — the model that ran this pass (reviewer or implementer,
                          despite the field name — matches the ticket's requested
                          shape). Nil when not captured (e.g. a stub fixture in
                          tests, which never emits a `result` event).
    * `reviewer_tier`   — the abstract `model_tier` (`"economy"` | `"standard"`
                          | `"premium"`) resolved for a `:review` row (bd-3xultf:
                          the reviewer's tier is the task's own tier bumped one
                          step). Always nil for `:impl` rows. Recorded alongside
                          `reviewer_model` so convergence analysis can segment by
                          the judge's tier instead of a moving reviewer reading
                          as a quality change.
    * `cost_usd`        — USD cost of this pass. Nil when not captured.
    * `criteria_total`  — number of acceptance criteria the reviewer addressed
                          in its per-criterion CRITERIA breakdown (bd-4yhv4x).
                          Nil when the pass carried no breakdown (an `:impl` row,
                          or a `:review` row on a task with no stated criteria).
    * `criteria_unmet`  — how many of those the breakdown marked `[NOT MET]`.
                          Nil alongside a nil `criteria_total`; makes "APPROVE
                          with N criteria unmet" queryable without re-reading
                          the reviewer transcript.
    * `finding_ids`     — JSON array of the `F<round>.<n>` ids this `:review` round
                          raised (bd-6r8caj). Nil for `:impl` rows and for a round
                          that raised none. Gives a finding an identity that
                          survives the round boundary, so round N+1 can be asked
                          "was F1.1 addressed?" — a question free prose could not
                          answer.
    * `dispositions`    — JSON object mapping every finding carried INTO this
                          `:review` round to what the round said about it:
                          `"addressed"` / `"not_addressed"` / `"obsolete"`, or
                          `"none"` when the round never mentioned it. Nil when
                          nothing was carried in (round 1) or for `:impl` rows.
    * `undispositioned_count`
                        — how many Medium-or-higher carried findings the round
                          left with no disposition. A `:review` APPROVE row with
                          a non-zero count IS the bd-8mtb0q defect, queryable
                          without re-reading the reviewer transcript.
    * `converged`       — true for a `:review` row whose verdict is `:approve`
                          AND whose CRITERIA breakdown left no criterion unmet;
                          false otherwise (including all `:impl` rows, and an
                          APPROVE that admits an unmet criterion).

  ## Metric start date

  Backfill is out of scope (bd-aqyjuc acceptance). Rows only exist for
  ReviewGate runs from 2026-07-28 onward — treat any convergence-rate or
  finding-category query as reflecting that window, not the system's full
  history.

  ## Retention

  Kept indefinitely, like `Arbiter.Reviews.Record`. No automatic purge.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.ReviewGate,
    data_layer: AshSqlite.DataLayer

  @roles ~w(review impl)a
  @verdicts ~w(approve request_changes)a

  sqlite do
    table "review_gate_rounds"
    repo Arbiter.Repo

    custom_indexes do
      index [:task_id, :inserted_at]
      index [:task_id, :round]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :task_id,
        :run_id,
        :round,
        :role,
        :verdict,
        :findings,
        :finding_count,
        :reviewer_model,
        :reviewer_tier,
        :cost_usd,
        :criteria_total,
        :criteria_unmet,
        :finding_ids,
        :dispositions,
        :undispositioned_count,
        :converged
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "Task under review (no synthetic #review/#implN suffix)."
    end

    attribute :run_id, :uuid do
      public? true
      description "FK-like pointer to the Arbiter.Workers.Run for this pass. Nil if unresolved."
    end

    attribute :round, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: @roles
      description ":review (reviewer pass) or :impl (implementer revise pass)."
    end

    attribute :verdict, :atom do
      public? true
      constraints one_of: @verdicts
      description "approve or request_changes; nil for :impl rows."
    end

    attribute :findings, :string do
      public? true
      description "Reviewer findings text, or the implementer's revise-response transcript."
    end

    attribute :finding_count, :integer do
      public? true
      description "Best-effort count of enumerated findings. Nil for :impl rows."
    end

    attribute :reviewer_model, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Model that ran this pass. Nil when not captured."
    end

    attribute :reviewer_tier, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Resolved model_tier for a :review row. Nil for :impl rows."
    end

    attribute :cost_usd, :float do
      public? true
      description "USD cost of this pass. Nil when not captured."
    end

    attribute :criteria_total, :integer do
      public? true
      constraints min: 0

      description "Acceptance criteria addressed in the reviewer's CRITERIA breakdown. Nil when no breakdown."
    end

    attribute :criteria_unmet, :integer do
      public? true
      constraints min: 0

      description "How many addressed criteria the breakdown marked [NOT MET]. Nil when no breakdown."
    end

    attribute :finding_ids, :string do
      public? true
      description "JSON array of the F<round>.<n> ids this review round raised. Nil when none."
    end

    attribute :dispositions, :string do
      public? true

      description "JSON object of carried-in finding id => addressed/not_addressed/obsolete/none."
    end

    attribute :undispositioned_count, :integer do
      public? true
      constraints min: 0

      description "Medium-or-higher carried findings this round left with no disposition."
    end

    attribute :converged, :boolean do
      allow_nil? false
      public? true
      default false
      description "True for a :review APPROVE with no criterion left unmet."
    end

    create_timestamp :inserted_at
  end

  @doc "All valid role atoms."
  def roles, do: @roles

  @doc "All valid verdict atoms."
  def verdicts, do: @verdicts
end
