defmodule Arbiter.Reviews do
  @moduledoc """
  Ash domain for durable external-review audit records.

  Every `ExternalReview` run — whether dispatched from the MCP tool, the
  REST API, or the CLI — persists a row in `external_review_records` so its
  behaviour can be queried, audited, and surfaced on the dashboard.

  See `Arbiter.Reviews.Record` for the schema.

  ## Retention

  Records are kept indefinitely by default. They are small (one row per
  external review) and the table is expected to grow slowly (one row per
  `worker_review pr:` invocation). Operators who want a rolling window can
  run:

      DELETE FROM external_review_records
      WHERE inserted_at < datetime('now', '-90 days');

  or schedule an equivalent job. No automatic purge is wired up by default —
  the audit history is meant to be durable.
  """

  use Ash.Domain

  resources do
    resource Arbiter.Reviews.Record
  end
end
