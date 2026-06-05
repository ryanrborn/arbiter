defmodule Arbiter.Polecats.Run do
  @moduledoc """
  Durable record of a single polecat run.

  Created when an `Arbiter.Polecat` GenServer initialises (status `:running`)
  and updated on terminal transitions (`:completed` or `:failed`). The polecat
  treats both writes as best-effort: a DB hiccup logs a warning but never
  crashes the workflow runner.

  `bead_title` is denormalised so the dashboard's history list never needs to
  join against `issues` on every render.

  `output_lines` stores the captured Claude / subprocess stdout, capped at
  `@max_output_lines` (see `Arbiter.Polecat`) to keep the row size sane. This
  is the bounded *tail* for the UI — the **full, uncapped** transcript is
  persisted append-only to an on-disk per-run file by
  `Arbiter.Polecat.OutputLog` (path `<output_log_root>/<id>.log`) and is the
  audit source of record. Retrieve it with `arb polecat log <bead-id>` or
  `GET /api/polecats/:bead_id/log`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Polecats,
    data_layer: AshSqlite.DataLayer

  @statuses ~w(running completed failed)a

  sqlite do
    table("polecat_runs")
    repo(Arbiter.Repo)

    custom_indexes do
      # Powers "completed acolytes for workspace W, optionally filtered by
      # status, newest first" — the dashboard's primary query shape.
      index([:workspace_id, :status, :started_at])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :bead_id,
        :bead_title,
        :rig,
        :workspace_id,
        :status,
        :started_at,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :resumed_from_run_id
      ])
    end

    update :update do
      primary?(true)
      require_atomic?(false)

      accept([
        :status,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :bead_title
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :bead_id, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 255, trim?: true)
      description("The bead this polecat worked.")
    end

    attribute :bead_title, :string do
      public?(true)
      constraints(max_length: 1000)
      description("Denormalised bead title; nil if the bead was already gone.")
    end

    attribute :rig, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 255, trim?: true)
    end

    attribute :workspace_id, :string do
      public?(true)
      constraints(max_length: 255, trim?: true)
      description("Workspace scope. Nullable for ad-hoc runs with no workspace.")
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:running)
      constraints(one_of: @statuses)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :completed_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :exit_code, :integer do
      public?(true)
      description("Subprocess exit status; nil if no subprocess (or still running).")
    end

    attribute :output_lines, {:array, :string} do
      public?(true)
      default([])
      description("Captured stdout lines (capped — see polecat write path).")
    end

    attribute :failure_reason, :string do
      public?(true)
      constraints(max_length: 2000)
    end

    attribute :resumed_from_run_id, :uuid do
      public?(true)

      description(
        "The prior run this run resumed from (bd-auma3z). Nullable; set only " <>
          "when an acolyte was resumed via `arb resume` rather than slung fresh, " <>
          "so the lineage of a stopped→resumed bead is traceable and metrics " <>
          "don't double-count a single bead's work as two unrelated runs."
      )
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  # ---- introspection -----------------------------------------------------

  @doc "All valid status atoms."
  def statuses, do: @statuses
end
