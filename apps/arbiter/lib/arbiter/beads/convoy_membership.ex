defmodule Arbiter.Beads.ConvoyMembership do
  @moduledoc """
  Join table: which issues belong to which convoys.

  Composite uniqueness on (convoy_id, issue_id). An issue can belong to many
  convoys, and a convoy can track many issues.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Beads,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "convoy_memberships"
    repo Arbiter.Repo

    references do
      reference :convoy, on_delete: :delete
      reference :issue, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:convoy_id, :issue_id]
    end

    # Idempotent attach: re-running with the same (convoy_id, issue_id) upserts
    # against the unique identity instead of raising. Lets the membership REST
    # endpoint be safely retried.
    create :add do
      accept [:convoy_id, :issue_id]
      upsert? true
      upsert_identity :convoy_issue_unique
    end
  end

  attributes do
    uuid_v7_primary_key :id
    create_timestamp :created_at
  end

  relationships do
    belongs_to :convoy, Arbiter.Beads.Convoy do
      allow_nil? false
      public? true
      attribute_writable? true
      attribute_type :string
    end

    belongs_to :issue, Arbiter.Beads.Issue do
      allow_nil? false
      public? true
      attribute_writable? true
      attribute_type :string
    end
  end

  identities do
    identity :convoy_issue_unique, [:convoy_id, :issue_id]
  end
end
