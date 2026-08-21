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

  ## Provenance (bd-dzz6ly)

  `resolved_skills`, `standing_orders_digest`, `routing_policy`, `model_tier`,
  `thinking`, and `difficulty_at_dispatch` record *what governed* the run, not
  just what happened — so "which runs had skill X active, grouped by outcome"
  is answerable without reading a transcript. Provenance recording started
  2026-07-29; runs before that date have these fields `nil` (backfill is out
  of scope — nil means "predates provenance," not "nothing applied").
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
  #
  # bd-8lq2g7 adds the two merge-queue *subordinate* passes, which run under the
  # task's own id alongside the parked primary: `:fix_pass` (CI fix on the open
  # PR) and `:conflict` (conflict resolution). They were previously recorded as
  # `:main`, making a failed subordinate read as the authoring worker failing.
  @worker_types ~w(main review impl fix_pass conflict)a

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

      # Powers "how did runs die, grouped by typed category" without a scan
      # (bd-apwfmy).
      index [:stop_category]
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
        :model,
        :status,
        :started_at,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :resumed_from_run_id,
        :mr_ref,
        :merger_url,
        :session_id,
        :config_dir,
        :difficulty_at_dispatch,
        :resolved_skills,
        :standing_orders_digest,
        :routing_policy,
        :model_tier,
        :thinking,
        :stop_category,
        :base_task_id,
        :role
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
        :task_title,
        :mr_ref,
        :merger_url,
        :session_id,
        :config_dir,
        :resolved_skills,
        :standing_orders_digest,
        :routing_policy,
        :model_tier,
        :thinking,
        :prompt_sha256,
        :result_subtype,
        :result_is_error,
        :result_message,
        :stop_category,
        :base_task_id,
        :role
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
                    ":review (review-gate or review-only reviewer), :impl " <>
                    "(review-gate revise-round implementer), :fix_pass " <>
                    "(merge-queue CI fix pass), or :conflict (merge-queue " <>
                    "conflict resolver)."
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

    attribute :mr_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The PR/MR ref this run opened or adopted (bd-6h4ia3). Nullable; a run " <>
                    "that never reached the merge step (or failed before opening one) has " <>
                    "no ref. Lets the task detail page show the full history of MRs a task " <>
                    "went through across its worker runs, not just the task's current " <>
                    "pr_ref (which is overwritten on each new MR)."
    end

    attribute :merger_url, :string do
      public? true
      constraints max_length: 2000, trim?: true
      description "Clickable link for mr_ref, resolved at record time (best-effort)."
    end

    # bd-au3xrq: identifying coordinates for this run's Claude Code on-disk
    # session JSONL (`<config_dir>/projects/<slug>/<session_id>.jsonl`), captured
    # so `Arbiter.Usage.ClaudeSessionFile` can reconcile token usage from disk
    # when the primary stdout path missed it (agent killed/crashed before the
    # terminal `result` event, or the node died mid-run). Both nullable: a
    # non-Claude run, or one that died before its `system/init` event, has no
    # session id to record.
    attribute :session_id, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Claude Code session id (== CLAUDE_CODE_SESSION_ID == the on-disk " <>
                    "session JSONL filename). Nullable; set once the session's init event lands."
    end

    attribute :config_dir, :string do
      public? true
      constraints max_length: 2000, trim?: true

      description "Effective CLAUDE_CONFIG_DIR the worker spawned under (workers use an " <>
                    "isolated dir, not ~/.claude). Roots the on-disk session JSONL lookup."
    end

    # ---- Run provenance (bd-dzz6ly) ---------------------------------------
    #
    # What GOVERNED this run, not just what happened. Populated best-effort,
    # in two waves: `difficulty_at_dispatch` is known before the worker even
    # starts (stamped into `record_run_started/1`'s create attrs from meta);
    # the rest are resolved later in the dispatch/spawn path (routing choice,
    # materialized skills, workspace config) and backfilled via the same
    # `:report` -> DB-patch path `:model` already uses. Nil on any run that
    # predates this column (added 2026-07-29) — backfill is explicitly out of
    # scope; a nil provenance field simply means "before we started recording
    # it," not "nothing applied."
    attribute :resolved_skills, {:array, :map} do
      public? true
      default []

      description "Effective post-layering skill set (workspace -> repo -> task) active " <>
                    "for this run: [{\"name\", \"activation_mode\", \"skill_version\"}, ...]. " <>
                    "\"skill_version\" is the skill's updated_at at dispatch time, so a later " <>
                    "edit to the skill body doesn't retroactively relabel this run's provenance."
    end

    attribute :standing_orders_digest, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "SHA-256 hex digest of the workspace's effective standing_orders text at " <>
                    "dispatch time. Nil when the workspace has no standing_orders configured."
    end

    attribute :routing_policy, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "Which routing policy decided the model/tier for this run " <>
                    "(\"static\" / \"by_priority\" / \"by_difficulty\" / \"by_budget\" / " <>
                    "\"round_robin\" / \"review_agent\" — the last for a ReviewGate reviewer, " <>
                    "which is configured directly rather than routed)."
    end

    attribute :model_tier, :string do
      public? true
      constraints max_length: 32, trim?: true

      description "Resolved abstract tier (\"economy\" / \"standard\" / \"premium\"), not just " <>
                    "the concrete model string already captured in :model."
    end

    attribute :thinking, :string do
      public? true
      constraints max_length: 32, trim?: true

      description "Resolved abstract reasoning effort (\"none\" / \"low\" / \"medium\" / \"high\")."
    end

    attribute :difficulty_at_dispatch, :integer do
      public? true
      constraints min: 0, max: 4

      description "The task's Issue.difficulty AT THE TIME this run was dispatched. A task's " <>
                    "difficulty can be edited later (bd-7rspia was corrected D1 -> D2 after the " <>
                    "fact) — reading the current issues.difficulty would silently attribute a " <>
                    "run to the corrected estimate rather than the one it actually ran under, " <>
                    "which would make difficulty-calibration analysis dishonest."
    end

    # ---- Prompt + result persistence (bd-9rdwe4) --------------------------
    #
    # What the agent was TOLD and how it actually ended, not just the
    # subprocess exit code. `prompt_sha256` anchors the redacted composed
    # prompt persisted alongside the transcript
    # (`Arbiter.Worker.PromptLog.path_for/1`); the `result_*` trio is the
    # structured terminal record pulled off the stream-json `result` event
    # (`Arbiter.Worker.ClaudeSession.absorb_usage/2`), so "what verdict did
    # runs under skill X reach" is answerable without an LLM re-reading a
    # transcript. Nil for a non-Claude / crashed / workflow-mode run — see
    # this migration's moduledoc for the graceful-degradation cases.
    attribute :prompt_sha256, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "SHA-256 hex of the redacted composed prompt persisted to " <>
                    "<output_log_root>/<run_id>.prompt, so identical prompts are cheaply " <>
                    "comparable without fetching the file."
    end

    attribute :result_subtype, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The terminal stream-json `result` event's `subtype` (e.g. \"success\", " <>
                    "\"error_max_turns\", \"error_during_execution\") — the CLI's own " <>
                    "outcome/verdict, distinct from the subprocess exit_code."
    end

    attribute :result_is_error, :boolean do
      public? true
      description "The terminal event's `is_error` flag."
    end

    attribute :result_message, :string do
      public? true
      constraints max_length: 20_000

      description "The terminal event's final assistant-facing text, redacted the same as " <>
                    "transcript lines. Truncated at 20,000 chars to keep the row bounded — " <>
                    "the full, untruncated transcript remains the audit source of record."
    end

    # bd-apwfmy: `failure_reason` above is `StopReason.summary` — the English
    # sentence. `Arbiter.Worker.StopReason.classify/2` computed a typed
    # `category` alongside it, at the moment of death and with the whole
    # captured output in hand, and Arbiter then threw the type away and made
    # every later consumer (`Loop.FailureClassifier`, `Worker.Dispatch`'s
    # context-thrash resume guard) re-derive it with a regex over transcript
    # prose. Keep the type. Nil on runs that ended any other way (a clean
    # completion, a review-gate rejection) and on runs predating the column.
    attribute :stop_category, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The run's typed terminal cause, stored as an atom name: an " <>
                    "Arbiter.Worker.StopReason category (\"auth_expired\", \"context_thrash\", " <>
                    "\"exited_without_done\", ...) or, for a worker parked by the commit gate, " <>
                    "that gate's reason (\"uncommitted_at_completion\", ...). The structured " <>
                    "twin of failure_reason's prose; nil when the run ended in neither."
    end

    # ---- Parent/role hierarchy (bd-5fhyry) ----------------------------------
    #
    # Replace suffix-encoded task-id hierarchy (`<base>#review`, `<base>#review#impl1`)
    # with real columns: `base_task_id` (the root task) plus `role` (denoting the
    # run's purpose: base/review/impl/etc), so hierarchy stops being string surgery
    # that a `WHERE task_id = ...` silently drops.
    attribute :base_task_id, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The root task id this run is part of (for ReviewGate review/impl " <>
                    "passes, this is the base task; for base runs, it equals task_id). " <>
                    "Nullable for now; populated for new runs and backfills."
    end

    attribute :role, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The role this worker played in the task's lifecycle: 'base' for the " <>
                    "main authoring run, 'review' for review-gate reviewer, 'impl' for " <>
                    "review-gate implementer, etc. Replaces suffix-encoded task_id hierarchy."
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
