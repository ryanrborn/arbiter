defmodule Arbiter.Workers.Run do
  @moduledoc """
  Durable record of a single worker run.

  Created when an `Arbiter.Worker` GenServer initialises (status `:running`)
  and updated on terminal transitions (`:completed` or `:failed`). The worker
  treats both writes as best-effort: a DB hiccup logs a warning but never
  crashes the workflow runner.

  `task_title` is denormalised so the dashboard's history list never needs to
  join against `issues` on every render. `worker_type` records which kind of
  worker produced the run (`:main` / `:review` / `:impl`) so a task's history
  shows *who* worked it at each step; `model` records the resolved agent model
  id once the session stream reports it.

  `output_lines` stores the captured Claude / subprocess stdout, capped at
  `@max_output_lines` (see `Arbiter.Worker`) to keep the row size sane. This
  is the bounded *tail* for the UI — the **full, uncapped** transcript is
  persisted append-only to an on-disk per-run file by
  `Arbiter.Worker.OutputLog` (path `<output_log_root>/<id>.log`) and is the
  audit source of record. Retrieve it with `arb worker log <task-id>` or
  `GET /api/workers/:task_id/log`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  @statuses ~w(running completed failed)a

  # The kind of worker that produced this run. A task can be worked by more
  # than one worker over its life: the `:main` worker that authors the change,
  # a `:review` worker (the review-gate reviewer or a coordinator-dispatched
  # review-only worker) that judges the diff, and an `:impl` worker (the
  # review-gate's revise-round implementer) that addresses findings. Recording
  # the type lets the history list show *who* worked the task at each step.
  @worker_types ~w(main review impl)a

  sqlite do
    table "worker_runs"
    repo Arbiter.Repo

    custom_indexes do
      # Powers "completed workers for workspace W, optionally filtered by
      # status, newest first" — the dashboard's primary query shape.
      index [:workspace_id, :status, :started_at]

      # Powers "all runs for task T, newest first" — the per-task history list
      # surfaced by `GET /api/workers/history?task_id=…` and `arb worker runs`.
      index [:task_id, :started_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :task_id,
        :task_title,
        :repo,
        :workspace_id,
        :worker_type,
        :status,
        :model,
        :started_at,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :resumed_from_run_id
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :status,
        :model,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :task_title
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "The task this worker worked."
    end

    attribute :task_title, :string do
      public? true
      constraints max_length: 1000
      description "Denormalised task title; nil if the task was already gone."
    end

    attribute :repo, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Workspace scope. Nullable for ad-hoc runs with no workspace."
    end

    attribute :worker_type, :atom do
      allow_nil? false
      public? true
      default :main
      constraints one_of: @worker_types

      description "Which kind of worker produced this run: :main (authoring), " <>
                    ":review (review-gate or review-only reviewer), or :impl " <>
                    "(review-gate revise-round implementer)."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :running
      constraints one_of: @statuses
    end

    attribute :model, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Resolved agent model id for the run (e.g. \"claude-opus-4-8\"); " <>
                    "nil for a no-agent run or before the stream reports one."
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    attribute :exit_code, :integer do
      public? true
      description "Subprocess exit status; nil if no subprocess (or still running)."
    end

    attribute :output_lines, {:array, :string} do
      public? true
      default []
      description "Captured stdout lines (capped — see worker write path)."
    end

    attribute :failure_reason, :string do
      public? true
      constraints max_length: 2000
    end

    attribute :resumed_from_run_id, :uuid do
      public? true

      description "The prior run this run resumed from (bd-auma3z). Nullable; set only " <>
                    "when an worker was resumed via `arb resume` rather than slung fresh, " <>
                    "so the lineage of a stopped→resumed task is traceable and metrics " <>
                    "don't double-count a single task's work as two unrelated runs."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # ---- introspection -----------------------------------------------------

  @doc "All valid status atoms."
  def statuses, do: @statuses

  @doc "All valid worker_type atoms."
  def worker_types, do: @worker_types
end
