defmodule Arbiter.Reviews.Record do
  @moduledoc """
  Durable audit record for each `ExternalReview` run (bd-31fh9e).

  One row is inserted when a review is dispatched (status `:running`) and
  updated to `:completed` or `:failed` when the workflow finishes. This gives
  operators visibility into in-flight reviews (via the dashboard) and a
  queryable history for auditing how external reviewers behave over time.

  ## Fields

    * `pr_ref`          — the opaque MR ref minted by the adapter (e.g.
                          `github:owner/repo#42`); stable and adapter-specific.
    * `pr`              — the raw identifier the caller passed (`--pr`), e.g.
                          a GitHub URL or a bare number.
    * `workspace_id`    — FK-like to the Workspace that ran the review.
    * `strategy`        — merge strategy: `"github"` / `"gitlab"` / `"direct"`.
    * `link`            — human-friendly URL to the PR on the forge (best-effort).
    * `status`          — `:running` while in flight, `:completed` on success,
                          `:failed` when the workflow errors.
    * `verdict`         — `:approve` or `:request_changes` (nil while running
                          or when the workflow failed before reaching the verdict
                          step).
    * `finding_count`   — number of findings the reviewer surfaced (nil while
                          running / on failure).
    * `findings_summary`— a short human-readable summary of the findings,
                          truncated at ~500 chars.
    * `model`           — model identifier used for the review (nil when a
                          stub check runner was injected and no real Claude
                          session ran).
    * `cost_usd`        — total USD cost (nil when not captured).
    * `tokens_in` / `tokens_out` — token counts (nil when not captured).
    * `dispatched_by`   — optional free-form string identifying the caller:
                          `"mcp"`, `"api"`, a task id, etc.
    * `engagement_id`   — the ReviewPatrol engagement created for this review,
                          or nil when follow-up was off.
    * `started_at`      — when the review was dispatched / `review/1` was called.
    * `completed_at`    — when the workflow finished (nil while running).

  ## Graceful degradation

  All cost/model/token fields are optional. A review using a stub check runner
  (tests, custom runners) writes a row with nil for those fields — the attempt
  is always visible. The default Claude invoker populates all four fields.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Reviews,
    data_layer: AshSqlite.DataLayer

  @verdicts ~w(approve request_changes)a
  @statuses ~w(running completed failed)a

  sqlite do
    table "external_review_records"
    repo Arbiter.Repo

    custom_indexes do
      index [:workspace_id, :started_at]
      index [:pr_ref]
      index [:status, :started_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :pr_ref,
        :pr,
        :workspace_id,
        :strategy,
        :link,
        :status,
        :verdict,
        :finding_count,
        :findings_summary,
        :model,
        :cost_usd,
        :tokens_in,
        :tokens_out,
        :dispatched_by,
        :engagement_id,
        :started_at,
        :completed_at
      ]
    end

    update :complete do
      accept [
        :status,
        :verdict,
        :finding_count,
        :findings_summary,
        :model,
        :cost_usd,
        :tokens_in,
        :tokens_out,
        :engagement_id,
        :completed_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :pr_ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
      description "Opaque MR ref minted by the adapter (e.g. github:owner/repo#42)."
    end

    attribute :pr, :string do
      public? true
      constraints max_length: 512, trim?: true
      description "Raw PR identifier passed by the caller (URL or number)."
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :strategy, :string do
      public? true
      constraints max_length: 64, trim?: true
      description "Merge strategy: github / gitlab / direct."
    end

    attribute :link, :string do
      public? true
      constraints max_length: 1024, trim?: true
      description "Human-friendly URL to the PR on the forge (best-effort)."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :running
      constraints one_of: @statuses
    end

    attribute :verdict, :atom do
      public? true
      constraints one_of: @verdicts
      description "approve or request_changes; nil while running or on failure."
    end

    attribute :finding_count, :integer do
      public? true
      description "Number of findings surfaced; nil while running or on failure."
    end

    attribute :findings_summary, :string do
      public? true
      description "Short summary of findings, truncated at ~500 chars."
    end

    attribute :model, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Model used for the review. Nil when not captured."
    end

    attribute :cost_usd, :float do
      public? true
      description "Total review cost in USD. Nil when not captured."
    end

    attribute :tokens_in, :integer do
      public? true
    end

    attribute :tokens_out, :integer do
      public? true
    end

    attribute :dispatched_by, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Optional caller identifier: 'mcp', 'api', a task id, etc."
    end

    attribute :engagement_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "ReviewPatrol engagement created for this review, or nil."
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the review was dispatched or review/1 was called."
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
      description "When the workflow finished; nil while running."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "All valid status atoms."
  def statuses, do: @statuses

  @doc "All valid verdict atoms."
  def verdicts, do: @verdicts
end
