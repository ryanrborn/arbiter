defmodule Arbiter.Usage.Event do
  @moduledoc """
  A single agent-session usage row.

  One row per finished Claude session (work worker or ReviewGate reviewer),
  inserted from `Arbiter.Worker` when the session port emits its terminal
  `result` event. The worker captures the structured fields off
  `Arbiter.Worker.ClaudeSession`'s session state — see `usage_summary/1`
  there.

  Multiple rows per bead are the point of this table: a re-slung bead writes
  a second `:work` row, a ReviewGate review adds a `:review` row, and so the
  spend-on-rework story falls out of `Arbiter.Usage.summarize/1` for free.

  ## Step

  `:work` — the worker's own session that produced the diff.
  `:review` — a ReviewGate-spawned reviewer session. `bead_id` carries the
              `#review` suffix used by `Arbiter.Worker.ReviewGate` so the row
              is still attributable to the bead being reviewed (drop the
              suffix at read time).
  `:other` — escape hatch for future non-Claude agents that don't fit the
              author/reviewer split.

  ## Graceful degradation

  Every cost / token / duration field is optional. A CLI that doesn't return
  structured usage still writes a row with `cost_usd: nil` so the *attempt* is
  visible — we never drop the row just because the numbers are missing.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Usage,
    data_layer: AshSqlite.DataLayer

  @steps ~w(work review other)a

  sqlite do
    table "usage_events"
    repo Arbiter.Repo

    custom_indexes do
      # Powers the per-workspace / per-day / per-bead dashboards. Keep narrow
      # — the table is small for now and we read it eagerly into memory in
      # Arbiter.Usage.summarize/1.
      index [:workspace_id, :occurred_at]
      index [:bead_id, :occurred_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :bead_id,
        :workspace_id,
        :repo,
        :step,
        :model,
        :provider,
        :tokens_in,
        :tokens_out,
        :cache_creation_tokens,
        :cache_read_tokens,
        :cost_usd,
        :duration_ms,
        :exit_status,
        :worker_run_id,
        :occurred_at,
        :session_id,
        :raw
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :bead_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "Bead this session worked. For ReviewGate reviewers carries a `#review` suffix."
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :repo, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :step, :atom do
      allow_nil? false
      public? true
      default :work
      constraints one_of: @steps
    end

    attribute :model, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :provider, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "Provider key (e.g. \"claude\", \"openai\"). Normalised so future non-Claude agents fit this same ledger."
    end

    attribute :tokens_in, :integer do
      public? true
    end

    attribute :tokens_out, :integer do
      public? true
    end

    attribute :cache_creation_tokens, :integer do
      public? true
    end

    attribute :cache_read_tokens, :integer do
      public? true
    end

    attribute :cost_usd, :float do
      public? true
      description "Total session cost in USD. Nil when the CLI didn't return structured cost."
    end

    attribute :duration_ms, :integer do
      public? true
    end

    attribute :exit_status, :integer do
      public? true
    end

    attribute :worker_run_id, :uuid do
      public? true

      description "FK-like pointer to the Arbiter.Workers.Run this session belonged to. Not a hard FK (the run row is best-effort)."
    end

    attribute :session_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Upstream session identifier from the CLI's `system/init` event, when present."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the session terminated (the `result` event arrival)."
    end

    attribute :raw, :map do
      public? true

      description "Original CLI usage payload (the parsed `result` event). Kept for forensic debugging; never queried."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "All valid step atoms."
  def steps, do: @steps
end
