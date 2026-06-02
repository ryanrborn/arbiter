defmodule Arbiter.Beads.Issue do
  @moduledoc """
  An Issue is a unit of work in the bead ledger. Equivalent to a bd "bead" in the
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
  falling back to `:none` if the workspace doesn't specify one. Override per-bead by
  passing `tracker_type:` to the create action.

  ## Audit

  Via `AshPaperTrail.Resource` extension. Every create / update / close / reopen
  produces a paper-trail version row capturing the diff + actor.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Beads,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  @statuses ~w(open in_progress closed)a
  @issue_types ~w(task bug feature epic chore decision)a
  @tracker_types ~w(none jira shortcut linear github)a

  postgres do
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
        :issue_type,
        :assignee,
        :tracker_type,
        :tracker_ref,
        :workspace_id
      ]

      change {Arbiter.Beads.Issue.Changes.GenerateId, []}
      change {Arbiter.Beads.Issue.Changes.InheritTrackerType, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Beads.Issue.broadcast_lifecycle(:created, issue)
               {:ok, issue}
             end)
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
        :issue_type,
        :assignee,
        :tracker_type,
        :tracker_ref
      ]

      require_atomic? false

      # Allow open ⇄ in_progress, but block transitions involving :closed via :update
      change {Arbiter.Beads.Issue.Changes.GuardStatus, action: :update}

      # Propagate an open ⇄ in_progress status change to the linked external
      # tracker. Best-effort; no-op when status didn't change or no tracker.
      change {Arbiter.Beads.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Beads.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    update :close do
      require_atomic? false
      argument :reason, :string

      change {Arbiter.Beads.Issue.Changes.GuardStatus, action: :close}
      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)

      # Best-effort teardown: stop the bead's polecat (if any) and remove
      # its worktree (if clean). Failures never fail the :close itself.
      # Runs for every :close path — CLI, Driver, Refinery.
      change {Arbiter.Beads.Issue.Changes.StopPolecat, []}
      change {Arbiter.Beads.Issue.Changes.CleanupWorktree, []}

      # Propagate the close to the linked external tracker (closes the GitHub
      # issue, etc.). Best-effort: a sync failure never fails the local close.
      change {Arbiter.Beads.Issue.Changes.SyncTracker, []}

      # After closing, check whether any system-managed convoy this issue belongs
      # to should auto-close. Safe no-op when issue isn't a member of any convoy.
      change after_action(fn _changeset, issue, _context ->
               Arbiter.Beads.Convoy.maybe_auto_close_for_issue(issue)
               Arbiter.Beads.Issue.broadcast_lifecycle(:closed, issue)
               {:ok, issue}
             end)
    end

    update :reopen do
      require_atomic? false

      change {Arbiter.Beads.Issue.Changes.GuardStatus, action: :reopen}
      change set_attribute(:status, :open)
      change set_attribute(:closed_at, nil)

      # Propagate the reopen to the linked external tracker (reopens the GitHub
      # issue, etc.). Best-effort: a sync failure never fails the local reopen.
      change {Arbiter.Beads.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Beads.Issue.broadcast_lifecycle(:reopened, issue)
               {:ok, issue}
             end)
    end
  end

  @doc false
  def broadcast_lifecycle(event, issue)
      when event in [:created, :updated, :closed, :reopened] do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, "beads", {:bead_lifecycle, event, issue})
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
      # with underscores or multiple hyphens (e.g. `ac-access_control-refinery`,
      # `vs-server-polecat-chrome`). Without that tolerance,
      # AshPaperTrail's Version row creation rejects those IDs and any
      # close/update on a legacy bead fails. Newly generated IDs are
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

    attribute :issue_type, :atom do
      allow_nil? false
      public? true
      default :task
      constraints one_of: @issue_types
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
      description "External tracker's ID for this bead (e.g. \"VR-17585\" for Jira)."
    end

    attribute :closed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Arbiter.Beads.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    has_many :convoy_memberships, Arbiter.Beads.ConvoyMembership do
      destination_attribute :issue_id
      public? true
    end

    many_to_many :convoys, Arbiter.Beads.Convoy do
      through Arbiter.Beads.ConvoyMembership
      source_attribute_on_join_resource :issue_id
      destination_attribute_on_join_resource :convoy_id
      public? true
    end
  end

  @doc "List of valid status atoms."
  def statuses, do: @statuses

  @doc "List of valid issue_type atoms."
  def issue_types, do: @issue_types

  @doc "List of valid tracker_type atoms."
  def tracker_types, do: @tracker_types

  @gating_dep_types [:blocks, :depends_on]

  @doc """
  Returns the list of "ready" issues — issues whose `status == :open` and which
  have no open gating dependencies (`:blocks` or `:depends_on` edges) whose
  target (`to_issue`) is itself not closed.

  Informational dep types (`:relates_to`, `:discovered_from`, `:parent_of`) do
  NOT gate readiness — only `:blocks` and `:depends_on` count.

  ## Options

    * `:workspace_id` — when set, restrict open issues to a single
      workspace. Gating dependencies are still consulted across
      workspaces (a bead in workspace A can be blocked by a bead in
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

      gating_deps =
        Arbiter.Beads.Dependency
        |> Ash.read!()
        |> Enum.filter(fn d ->
          d.type in @gating_dep_types and MapSet.member?(open_ids, d.from_issue_id)
        end)

      if gating_deps == [] do
        open_issues
      else
        target_ids = gating_deps |> Enum.map(& &1.to_issue_id) |> Enum.uniq()

        targets_by_id =
          target_ids
          |> Enum.map(&Ash.get!(__MODULE__, &1))
          |> Map.new(&{&1.id, &1})

        blocked_from_ids =
          gating_deps
          |> Enum.filter(fn d ->
            case Map.fetch(targets_by_id, d.to_issue_id) do
              {:ok, target} -> target.status != :closed
              :error -> false
            end
          end)
          |> Enum.map(& &1.from_issue_id)
          |> MapSet.new()

        Enum.reject(open_issues, fn i -> MapSet.member?(blocked_from_ids, i.id) end)
      end
    end
  end
end
