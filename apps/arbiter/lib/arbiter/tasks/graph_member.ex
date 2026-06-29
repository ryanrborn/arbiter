defmodule Arbiter.Tasks.GraphMember do
  @moduledoc """
  `GraphMember` is the join resource between a `Graph` and an `Issue` (directive).

  A directive may belong to multiple graphs. A graph may contain many directives.
  Ordering and blocking relationships between directives are expressed via the
  existing `Arbiter.Tasks.Dependency` edges — this resource does NOT add new
  edges; it only tracks set membership.

  The unique identity on `(graph_id, issue_id)` prevents duplicate membership
  rows for the same directive in the same graph.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "graph_members"
    repo Arbiter.Repo

    references do
      reference :graph, on_delete: :delete
      reference :issue, on_delete: :restrict
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:graph_id, :issue_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :graph_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :issue_id, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :graph, Arbiter.Tasks.Graph do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :issue, Arbiter.Tasks.Issue do
      allow_nil? false
      public? true
      attribute_writable? true
      attribute_type :string
    end
  end

  identities do
    identity :unique_membership, [:graph_id, :issue_id]
  end
end
