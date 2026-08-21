defmodule Arbiter.Workers.RunStep do
  @moduledoc """
  A single typed tool-call observation inside a worker run.

  Phase 1 of bd-apwfmy: promote `tool_use`/`tool_result` block pairs out of
  rendered transcript prose into a queryable row, instead of discarding their
  structure once `Arbiter.Worker.ClaudeSession` has formatted them into
  display lines (see `tool_result_lines/1` / `assistant_block_lines/1` there).

  One row per matched tool call, written when the `tool_result` block
  arrives (so `duration_ms` is available) and correlated back to its
  `tool_use` block by `tool_use_id`. A `tool_use` with no matching result
  (session killed mid-call) writes no row — absent, not garbage, per the
  parent issue's acceptance bar.

  `input_summary`/`output_summary` are bounded, redacted strings — reuses the
  transcript's own `Arbiter.Redaction` choke-point, never a second path a
  secret could slip through. `input_digest` is a sha256 of the redacted input,
  cheap enough to compare for retry/thrash detection without re-parsing JSON.

  Best-effort, like `Arbiter.Usage.Event`: a write failure here logs a
  warning and never fails the run.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "worker_run_steps"
    repo Arbiter.Repo

    custom_indexes do
      # Powers "all steps for run R, in order" — the per-run timeline query.
      index [:run_id, :occurred_at]

      # Powers "tool error rate for tool T" / "p50/p95 duration for tool T"
      # rollups across runs.
      index [:name]

      # Lets a rollup exclude (or isolate) backfilled rows, whose timing and
      # redaction provenance differ from live capture. See `:source`.
      index [:source]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :run_id,
        :task_id,
        :tool_use_id,
        :name,
        :is_error,
        :duration_ms,
        :input_digest,
        :input_summary,
        :output_summary,
        :occurred_at,
        :source
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid do
      public? true

      description "FK-like pointer to the Arbiter.Workers.Run this step belonged to. Not a hard FK (best-effort, like usage_events.worker_run_id)."
    end

    attribute :task_id, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :tool_use_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true

      description "The Claude stream-json tool_use block's `id`, echoed on its tool_result as `tool_use_id`. The correlation key that makes duration_ms computable."
    end

    attribute :name, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Tool name, from the matched tool_use block. Nil if the tool_result arrived with no matching pending tool_use (unexpected but non-fatal)."
    end

    attribute :is_error, :boolean do
      allow_nil? false
      public? true
      default false

      description "block[\"is_error\"] straight from the tool_result block, as a real boolean — not inferred from the rendered \"tool error\" display string."
    end

    attribute :duration_ms, :integer do
      public? true

      description "Wall-clock time between the matched tool_use block being seen and this tool_result arriving. Nil when no matching tool_use was pending."
    end

    attribute :input_digest, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "sha256 (hex) of the redacted tool_use input, for cheap same-call-again comparisons (retry/thrash detection)."
    end

    attribute :input_summary, :string do
      public? true
      constraints max_length: 2048, trim?: true

      description "Bounded, redacted summary of the tool_use input (reuses ClaudeSession's summarize_tool_input/1)."
    end

    attribute :output_summary, :string do
      public? true
      constraints max_length: 2048, trim?: true
      description "Bounded, redacted summary of the tool_result content."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the tool_result block was processed."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      default "live"
      constraints max_length: 16, trim?: true

      description "How this row was captured: \"live\" (written by the ClaudeSession emit path as the run happened) or \"backfill\" (reconstructed by Arbiter.Workers.StepBackfill from the on-disk session JSONL). Backfilled rows carry line-timestamp timing rather than monotonic-clock timing, and were redacted against today's known secret values rather than the run's own — provenance worth being able to filter on."
    end

    create_timestamp :inserted_at
  end
end
