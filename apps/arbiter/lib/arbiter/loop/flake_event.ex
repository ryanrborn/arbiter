defmodule Arbiter.Loop.FlakeEvent do
  @moduledoc """
  One append-only row recording that a fix_pass concluded a CI failure was a
  flake or infra issue rather than a code defect (bd-6vullc).

  `Arbiter.Loop.Flakes.record/1` is the only writer — the `flake_record` MCP
  tool is its only call site. `Arbiter.Loop.Corpus` reads this table
  (windowed, raw SQL, like every other Loop corpus read) to feed
  `Arbiter.Loop.CiSection`'s recurring-flake grouping.

  ## Fields

    * `task_id`    — the fix_pass's task.
    * `run_id`     — the fix_pass's `worker_runs.id`, when it could be
                     resolved. Nil rather than a required foreign key: a
                     fix_pass whose run row already went missing (a very
                     late call, a race) should still be able to record the
                     event.
    * `repo`       — the repo the CI failure was on.
    * `ci_job`     — the failing CI job/check name.
    * `test_file`  / `test_line` — the failing test's location, when the
                     worker could identify one (a lint/build/infra flake
                     often has neither).
    * `signature`  — a short, worker-authored failure signature (e.g. a log
                     line fragment), used to group recurrences that don't
                     share a `test_file`/`test_line`.
    * `note`       — the worker's evidence for the flake/infra verdict.
    * `recorded_at`— when the event was recorded.

  ## Append-only

  No update or destroy action — a correction is a new row.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Loop,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "flake_events"
    repo Arbiter.Repo

    custom_indexes do
      index [:task_id]
      index [:repo, :signature]
      index [:repo, :test_file, :test_line]
      index [:recorded_at]
    end
  end

  actions do
    create :record do
      primary? true

      accept [
        :task_id,
        :run_id,
        :repo,
        :ci_job,
        :test_file,
        :test_line,
        :signature,
        :note,
        :recorded_at
      ]
    end

    read :read do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :run_id, :uuid do
      public? true
      description "The fix_pass's worker_runs.id, when resolvable."
    end

    attribute :repo, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :ci_job, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
    end

    attribute :test_file, :string do
      public? true
      constraints max_length: 1024, trim?: true
    end

    attribute :test_line, :integer do
      public? true
    end

    attribute :signature, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
    end

    attribute :note, :string do
      public? true
      constraints max_length: 2_000, trim?: true
    end

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
  end
end
