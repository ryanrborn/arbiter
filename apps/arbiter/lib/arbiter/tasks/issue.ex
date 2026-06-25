defmodule Arbiter.Tasks.Issue do
  @moduledoc """
  An Issue is a unit of work in the task ledger. Equivalent to a bd "task" in the
  Go implementation: title, description, status, priority, dependencies, audit trail,
  optional external-tracker reference.

  IDs are human-friendly strings: `"{workspace.prefix}-{short_id}"`, e.g. `"bd-3o8"`,
  `"verus-VR17575"`. The short_id is a 6-char base36 random; collisions are
  negligible at our scale.

  ## Status FSM

      :open ⇄ :in_progress
       │          │
       └────►─────┴────► :closed
                          │
                          └ reopen → :open

  Enforced in `:update`, `:close`, `:reopen` actions. You cannot close an already
  closed issue, and cannot transition out of :closed without an explicit `:reopen`.

  ## Rich-content fields

  All Markdown: `description`, `acceptance`, `notes`, `qa_notes`, `deployment_notes`.
  Stored verbatim. Adapters (Tracker.Jira etc., gte-029) convert to the external
  format (ADF for Jira, native Markdown for Linear/GitHub) at write-time.

  ## External tracker

  `tracker_type` defaults to the workspace's tracker.type (from `Workspace.config`),
  falling back to `:none` if the workspace doesn't specify one. Override per-task by
  passing `tracker_type:` to the create action.

  ## Audit

  Via `AshPaperTrail.Resource` extension. Every create / update / close / reopen
  produces a paper-trail version row capturing the diff + actor.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  require Ash.Query

  @statuses ~w(open in_progress closed)a
  @issue_types ~w(task bug feature epic chore decision)a
  @tracker_types ~w(none jira shortcut linear github gitlab)a

  sqlite do
    table "issues"
    repo Arbiter.Repo

    references do
      reference :workspace, on_delete: :restrict
    end
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    ignore_attributes([:created_at, :updated_at])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :title,
        :description,
        :acceptance,
        :notes,
        :qa_notes,
        :deployment_notes,
        :priority,
        :difficulty,
        :issue_type,
        :auto_close,
        :assignee,
        :tracker_type,
        :tracker_ref,
        :target_branch,
        :workspace_id
      ]

      # Opt-out for `arb create --no-tracker` / `--local-only`. When true, the
      # CreateUpstream hook skips the outbound-create call even when the
      # workspace has a tracker configured.
      argument :skip_upstream_create, :boolean, default: false

      change {Arbiter.Tasks.Issue.Changes.GenerateId, []}
      change {Arbiter.Tasks.Issue.Changes.InheritTrackerType, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:created, issue)
               {:ok, issue}
             end)

      # Mirror the new task into the workspace's configured tracker. Runs in
      # after_transaction so the task is committed first — an upstream
      # failure surfaces as `{:error, %{kind: :upstream_create_failed, ...}}`
      # to the caller but leaves the task intact.
      change {Arbiter.Tasks.Issue.Changes.CreateUpstream, []}
    end

    update :update do
      primary? true

      accept [
        :title,
        :description,
        :acceptance,
        :notes,
        :qa_notes,
        :deployment_notes,
        :status,
        :priority,
        :difficulty,
        :issue_type,
        :auto_close,
        :assignee,
        :tracker_type,
        :tracker_ref,
        :pr_ref,
        :pr_body,
        :target_branch
      ]

      require_atomic? false

      # Allow open ⇄ in_progress, but block transitions involving :closed via :update
      change {Arbiter.Tasks.Issue.Changes.GuardStatus, action: :update}

      # Propagate an open ⇄ in_progress status change to the linked external
      # tracker. Best-effort; no-op when status didn't change or no tracker.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      # Propagate title/description changes to the linked external tracker.
      # Best-effort; no-op when neither field changed or no tracker.
      change {Arbiter.Tasks.Issue.Changes.SyncFields, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    update :close do
      require_atomic? false
      argument :reason, :string
      argument :close_upstream, :boolean, default: false

      change {Arbiter.Tasks.Issue.Changes.GuardStatus, action: :close}
      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)

      # Best-effort teardown: stop the task's worker (if any) and remove
      # its worktree (if clean). Failures never fail the :close itself.
      # Runs for every :close path — CLI, Driver, MergeQueue.
      change {Arbiter.Tasks.Issue.Changes.StopWorker, []}
      change {Arbiter.Tasks.Issue.Changes.CleanupWorktree, []}

      # Propagate the close to the linked external tracker only when
      # close_upstream: true is explicitly passed. Default is to leave the
      # upstream issue open (e.g. task abandoned, ceded, or pruned).
      # Best-effort: a sync failure never fails the local close.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      # After closing, roll the closure up to any auto-close parent of this task
      # (a `:parent_of` epic that should close once all its children are done),
      # then broadcast the closure. Both run via after_transaction (post-commit)
      # rather than after_action (pre-commit), so LiveView queries from separate
      # DB connections see the committed state and the dashboard updates
      # correctly when a directive is completed.
      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.maybe_auto_close_parents(issue)
            Arbiter.Tasks.Issue.broadcast_lifecycle(:closed, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    update :reopen do
      require_atomic? false

      change {Arbiter.Tasks.Issue.Changes.GuardStatus, action: :reopen}
      change set_attribute(:status, :open)
      change set_attribute(:closed_at, nil)

      # Propagate the reopen to the linked external tracker (reopens the GitHub
      # issue, etc.). Best-effort: a sync failure never fails the local reopen.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:reopened, issue)
               {:ok, issue}
             end)
    end
  end

  @doc false
  def broadcast_lifecycle(event, issue)
      when event in [:created, :updated, :closed, :reopened] do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, "tasks", {:task_lifecycle, event, issue})

    if ws_id = Map.get(issue, :workspace_id) do
      Arbiter.Events.broadcast(ws_id, "task_state", %{
        task_id: Map.get(issue, :id),
        event: to_string(event),
        status: to_string(Map.get(issue, :status) || "")
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      # Pattern allows uppercase to accommodate phase markers (gte-P1),
      # Verus-style mixed-case IDs from the Dolt import, AND legacy IDs
      # with underscores or multiple hyphens (e.g. `ac-access_control-merge_queue`,
      # `vs-server-worker-chrome`). Without that tolerance,
      # AshPaperTrail's Version row creation rejects those IDs and any
      # close/update on a legacy task fails. Newly generated IDs are
      # still tidy lowercase prefix-shortid (see Changes.GenerateId).
      constraints match: ~r/^[a-z][a-zA-Z0-9]*-[a-zA-Z0-9_-]+$/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
    end

    attribute :description, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :acceptance, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :notes, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :qa_notes, :string do
      public? true
      default ""
      description "Markdown. Synced to Jira's QA Testing Notes custom field via Tracker.Jira."
    end

    attribute :deployment_notes, :string do
      public? true
      default ""
      description "Markdown. Synced to Jira's Deployment Notes custom field via Tracker.Jira."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: @statuses
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 2
      constraints min: 0, max: 4
      description "0 = P0 (highest), 4 = P4 (lowest). Default 2 (P2)."
    end

    attribute :difficulty, :integer do
      public? true
      constraints min: 0, max: 4

      description """
      How hard the task is (0..4 / D0..D4). Orthogonal to :priority.
      Drives provider-agnostic model/thinking routing via
      `Arbiter.Agents.Routing.ByDifficulty`. Nullable; routing treats
      `nil` as D2 (the default tier).

      D0 Trivial  — single-file, fully specified, no judgment.
      D1 Simple   — localized, clear approach, light reasoning.
      D2 Moderate — multi-file or some design choice (default).
      D3 Hard     — cross-cutting, non-obvious design, correctness-critical.
      D4 Extreme  — novel architecture, deep ambiguity, may warrant multi-pass.
      """
    end

    attribute :issue_type, :atom do
      allow_nil? false
      public? true
      # bd-5lc99r: `:task` is now an OPT-IN non-reviewable type (ops/research/
      # spikes — deliverable is a findings summary in `notes`, no commit/review/
      # PR). Because the catch-all creation paths (CLI `arb create` without
      # `--type`, tracker/GitHub sync in Tasks.Claim, the REST API, untyped MCP
      # creates) fall through to this default, it MUST be a reviewable type or
      # every untyped coding task would silently skip the worktree/commit/review
      # path. `:feature` is the generic reviewable default; choose `:task`
      # explicitly to get the non-reviewable findings workflow.
      default :feature
      constraints one_of: @issue_types
    end

    attribute :auto_close, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      When true, this task auto-closes once ALL of its `:parent_of` children
      are closed (and there is at least one child). This is the parent-with-
      progress flag that replaces the old Convoy `:system_managed` vs `:owned`
      lifecycle: `auto_close: true` ≈ system_managed, `false` ≈ owned (the user
      closes the parent explicitly). Default `false`.
      """
    end

    attribute :assignee, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :tracker_type, :atom do
      allow_nil? false
      public? true
      default :none
      constraints one_of: @tracker_types
    end

    attribute :tracker_ref, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "External tracker's ID for this task (e.g. \"VR-17585\" for Jira)."
    end

    attribute :pr_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "PR/MR number opened for this task (e.g. \"123\"). Set by the merger when a PR is opened; distinct from tracker_ref which holds the originating issue ref."
    end

    attribute :pr_body, :string do
      public? true
      default ""

      description """
      Markdown. The worker-authored PR/MR description, written at completion
      (Summary / Test plan / References) reflecting the change that actually
      landed — and filling the repo's PR template when one exists. The MergeQueue
      opens the single canonical PR with this body, so the worker never opens
      its own PR. Distinct from `description` (the originating ticket spec).
      """
    end

    attribute :target_branch, :string do
      public? true
      constraints max_length: 255, trim?: true

      description """
      The branch this task's work is based on AND the PR merge target.
      Nullable; when unset the effective target is resolved from the repo's
      default, then the workspace's `merge.base`, then `"main"`.
      """
    end

    attribute :closed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  calculations do
    # Progress rollup over this task's `:parent_of` children. SQLite can't do
    # inline aggregates across the dependency join, so these are batch module
    # calculations (see Arbiter.Tasks.Issue.Calcs). Load with
    # `Ash.load!(issue, [:child_total, :child_closed])`.
    calculate :child_total, :integer, Arbiter.Tasks.Issue.Calcs.ChildTotal do
      public? true
    end

    calculate :child_closed, :integer, Arbiter.Tasks.Issue.Calcs.ChildClosed do
      public? true
    end
  end

  @doc "List of valid status atoms."
  def statuses, do: @statuses

  @doc "List of valid issue_type atoms."
  def issue_types, do: @issue_types

  @doc "List of valid tracker_type atoms."
  def tracker_types, do: @tracker_types

  @doc """
  Returns the list of "ready" issues — issues whose `status == :open` and which
  have no open gating dependencies (`:blocks` or `:depends_on` edges) whose
  relevant blocker is itself not closed.

  Informational dep types (`:relates_to`, `:discovered_from`, `:parent_of`) do
  NOT gate readiness — only `:blocks` and `:depends_on` count.

  ## Options

    * `:workspace_id` — when set, restrict open issues to a single
      workspace. Gating dependencies are still consulted across
      workspaces (a task in workspace A can be blocked by a task in
      workspace B). Default: no filter (all workspaces).

  Done in two passes:

    1. Read all open issues (filtered by workspace if given).
    2. Read all gating Dependency rows where `from_issue_id` is in that set;
       join their `to_issue` and check status.
    3. Reject open issues that have at least one unclosed gating target.

  At our scale (~thousands of issues) this is fine. If the graph grows, push the
  filter into Postgres with a `not exists` subquery as a read action.
  """
  def ready(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    open_issues =
      __MODULE__
      |> Ash.read!()
      |> Enum.filter(fn i ->
        i.status == :open and (is_nil(workspace_id) or i.workspace_id == workspace_id)
      end)

    if open_issues == [] do
      []
    else
      open_ids = MapSet.new(open_issues, & &1.id)
      all_deps = Ash.read!(Arbiter.Tasks.Dependency)

      # :depends_on — from=blocked_candidate, to=blocker.
      # Candidate is blocked while the blocker (to_issue) is not closed.
      depends_on_gating =
        Enum.filter(all_deps, fn d ->
          d.type == :depends_on and MapSet.member?(open_ids, d.from_issue_id)
        end)

      # :blocks — from=blocker, to=blocked_candidate.
      # Candidate (to_issue) is blocked while the blocker (from_issue) is not closed.
      # We must filter on to_issue_id here — the blocker may be :in_progress (not
      # in open_ids), which is the shape that caused the false-ready bug.
      blocks_gating =
        Enum.filter(all_deps, fn d ->
          d.type == :blocks and MapSet.member?(open_ids, d.to_issue_id)
        end)

      if depends_on_gating == [] and blocks_gating == [] do
        open_issues
      else
        issues_to_fetch =
          (Enum.map(depends_on_gating, & &1.to_issue_id) ++
             Enum.map(blocks_gating, & &1.from_issue_id))
          |> Enum.uniq()

        fetched_by_id =
          issues_to_fetch
          |> Enum.map(&Ash.get!(__MODULE__, &1))
          |> Map.new(&{&1.id, &1})

        # :depends_on: blocked if the dependency target (to_issue) is not closed
        blocked_by_depends_on =
          depends_on_gating
          |> Enum.filter(fn d ->
            case Map.fetch(fetched_by_id, d.to_issue_id) do
              {:ok, target} -> target.status != :closed
              :error -> false
            end
          end)
          |> Enum.map(& &1.from_issue_id)

        # :blocks: blocked if the blocker (from_issue) is not closed
        blocked_by_blocks =
          blocks_gating
          |> Enum.filter(fn d ->
            case Map.fetch(fetched_by_id, d.from_issue_id) do
              {:ok, blocker} -> blocker.status != :closed
              :error -> false
            end
          end)
          |> Enum.map(& &1.to_issue_id)

        blocked_from_ids =
          MapSet.new(blocked_by_depends_on ++ blocked_by_blocks)

        Enum.reject(open_issues, fn i -> MapSet.member?(blocked_from_ids, i.id) end)
      end
    end
  end

  # ---- parent-with-progress rollup ---------------------------------------

  @doc """
  Walk the `:parent_of` parents of `issue` and call `maybe_auto_close/1` on
  each. Intended for the `after_transaction` hook on `Issue.close`: when a child
  closes, any auto-close parent whose children are now all done closes too.
  Returns `:ok`.
  """
  def maybe_auto_close_parents(issue) do
    issue.id
    |> parents_of()
    |> Enum.each(&maybe_auto_close/1)

    :ok
  end

  @doc """
  If `parent` has `auto_close` set, is still open, and all its (≥1) `:parent_of`
  children are closed, close it with reason "all children closed". Returns the
  (possibly updated) parent task. Safe to call repeatedly.

  Closing the parent runs the normal `:close` action — including this same
  rollup — so the closure cascades up a chain of auto-close epics.
  """
  def maybe_auto_close(parent) do
    parent = Ash.load!(parent, [:child_total, :child_closed])

    cond do
      not parent.auto_close ->
        parent

      parent.status == :closed ->
        parent

      parent.child_total == 0 ->
        parent

      parent.child_closed < parent.child_total ->
        parent

      true ->
        {:ok, closed} =
          Ash.update(parent, %{reason: "all children closed"}, action: :close)

        closed
    end
  end

  # The parent tasks of `child_id`: the `from_issue` of every `:parent_of` edge
  # pointing at it. A child may have more than one parent.
  defp parents_of(child_id) do
    parent_of = :parent_of

    Arbiter.Tasks.Dependency
    |> Ash.Query.filter(type == ^parent_of and to_issue_id == ^child_id)
    |> Ash.read!()
    |> Enum.map(& &1.from_issue_id)
    |> Enum.uniq()
    |> Enum.map(&Ash.get!(__MODULE__, &1))
  end
end
