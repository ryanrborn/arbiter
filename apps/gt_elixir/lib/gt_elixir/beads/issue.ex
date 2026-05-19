defmodule GtElixir.Beads.Issue do
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
    otp_app: :gt_elixir,
    domain: GtElixir.Beads,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  @statuses ~w(open in_progress closed)a
  @issue_types ~w(task bug feature epic chore decision)a
  @tracker_types ~w(none jira linear github)a

  postgres do
    table "issues"
    repo GtElixir.Repo

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

      change {GtElixir.Beads.Issue.Changes.GenerateId, []}
      change {GtElixir.Beads.Issue.Changes.InheritTrackerType, []}
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
      change {GtElixir.Beads.Issue.Changes.GuardStatus, action: :update}
    end

    update :close do
      require_atomic? false
      argument :reason, :string

      change {GtElixir.Beads.Issue.Changes.GuardStatus, action: :close}
      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)

      # After closing, check whether any system-managed convoy this issue belongs
      # to should auto-close. Safe no-op when issue isn't a member of any convoy.
      change after_action(fn _changeset, issue, _context ->
               GtElixir.Beads.Convoy.maybe_auto_close_for_issue(issue)
               {:ok, issue}
             end)
    end

    update :reopen do
      require_atomic? false

      change {GtElixir.Beads.Issue.Changes.GuardStatus, action: :reopen}
      change set_attribute(:status, :open)
      change set_attribute(:closed_at, nil)
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z][a-z0-9]*-[a-z0-9]+$/
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
    belongs_to :workspace, GtElixir.Beads.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    has_many :convoy_memberships, GtElixir.Beads.ConvoyMembership do
      destination_attribute :issue_id
      public? true
    end

    many_to_many :convoys, GtElixir.Beads.Convoy do
      through GtElixir.Beads.ConvoyMembership
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
end
