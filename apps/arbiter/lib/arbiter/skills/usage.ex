defmodule Arbiter.Skills.Usage do
  @moduledoc """
  Tracks skill usage metrics: materialize_count, invoke_count, patch_count.

  bd-61hnbb: Per-skill usage telemetry to understand which skills are actually
  used vs just materialized. Counters increment at:
  - materialize_count: dispatch-time skill selection
  - invoke_count: slash invocation in worker transcript
  - patch_count: skill update (Skills.update_skill/2)
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Skills,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "skills_usage"
    repo Arbiter.Repo

    references do
      reference :skill, on_delete: :delete
    end

    custom_indexes do
      index [:skill_id], unique: true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:skill_id, :materialize_count, :invoke_count, :patch_count]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :materialize_count,
        :invoke_count,
        :patch_count,
        :last_materialized_at,
        :last_invoked_at,
        :last_patched_at
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :materialize_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Number of times this skill was materialized to a worker."
    end

    attribute :invoke_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Number of times this skill was invoked (/<name> in transcript)."
    end

    attribute :patch_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Number of times this skill was updated."
    end

    attribute :last_materialized_at, :utc_datetime do
      public? true
      description "Timestamp of the most recent materialization."
    end

    attribute :last_invoked_at, :utc_datetime do
      public? true
      description "Timestamp of the most recent invocation."
    end

    attribute :last_patched_at, :utc_datetime do
      public? true
      description "Timestamp of the most recent patch/update."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :skill, Arbiter.Skills.Skill do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_skill, [:skill_id], eager_check?: true
  end
end
