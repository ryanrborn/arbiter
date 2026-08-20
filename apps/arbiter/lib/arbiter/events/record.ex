defmodule Arbiter.Events.Record do
  @moduledoc """
  Durable row for a broadcast fired via `Arbiter.Events.broadcast/3`.

  Written synchronously, right before the live PubSub broadcast, from
  `Arbiter.Events.broadcast/3`. `seq` is an autoincrementing integer and is
  the cursor a reconnecting coordinator passes as `?since=` to `GET /events`
  — see `Arbiter.Events.replay/3`.

  Unlike the live broadcast (best-effort, swallowed on failure), a persist
  failure here is logged at `:error` rather than swallowed — see
  `Arbiter.Events.broadcast/3`.

  Retention is handled by `Arbiter.Events.Retention`, not by this resource.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Events,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "events"
    repo Arbiter.Repo

    custom_indexes do
      # Powers `Arbiter.Events.replay/3`: "topic in (...) and seq > cursor,
      # scoped to a workspace (or unscoped for a workspace-agnostic
      # coordinator token)".
      index [:workspace_id, :seq]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:workspace_id, :topic, :payload, :occurred_at]
    end
  end

  attributes do
    integer_primary_key :seq

    attribute :workspace_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :topic, :string do
      allow_nil? false
      public? true
      constraints max_length: 64, trim?: true
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
      default %{}

      description "The full event map as broadcast (topic, at, and caller-supplied fields), minus :cursor."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end
end
