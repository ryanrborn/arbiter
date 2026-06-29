defmodule Arbiter.Tasks.Graph do
  @moduledoc """
  A `Graph` is an execution unit: a named set of directives (Issues) that are
  executed together as a unit. Orthogonal to epics — an epic groups tasks by
  domain, a graph groups tasks by execution intent. A directive may belong to
  multiple graphs; a graph may span multiple epics.

  ## Run state FSM

      :draft ──► :running ──► :paused ──► :running
                     │              │
                     └──────────────┴──► :drained

  `draft`   — Graph is being assembled; no execution has started.
  `running` — Active execution underway.
  `paused`  — Execution suspended; can resume to :running.
  `drained` — All work complete; terminal state.

  ## Members

  Directives are linked via `Arbiter.Tasks.GraphMember`. The existing
  `Arbiter.Tasks.Dependency` edges between directives are reused for ordering —
  this resource does NOT duplicate the edge model.

  ## Scope

  Each graph belongs to a workspace. Cross-workspace graphs are not supported.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  @run_states ~w(draft running paused drained)a

  sqlite do
    table "graphs"
    repo Arbiter.Repo

    references do
      reference :workspace, on_delete: :restrict
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :run_state, :workspace_id]
    end

    update :update do
      primary? true
      accept [:name, :description, :run_state]
      require_atomic? false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
    end

    attribute :description, :string do
      public? true
      default ""
      description "Markdown. Optional summary of what this graph represents."
    end

    attribute :run_state, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: @run_states
      description "Execution phase: draft → running ⇄ paused → drained."
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

    has_many :members, Arbiter.Tasks.GraphMember do
      public? true
    end
  end

  @doc "List of valid run-state atoms."
  def run_states, do: @run_states
end
