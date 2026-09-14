defmodule Arbiter.Reviews.Coverage.Entry do
  @moduledoc """
  One append-only row of review coverage (`docs/review-coverage-and-guard-policy.md`
  §3.1, design #1635). Nothing mutates a row; a new approval, mechanical
  equivalence, or operator override adds a new row.

  `Arbiter.Reviews.Coverage.record/1` is the only writer — see its
  moduledoc. This resource is P0: **nothing reads this table yet** and no
  call site writes it yet either; that wiring is P1.

  ## Fields

    * `task_id`     — the authoring task (not the reviewer/watchdog task).
    * `mr_ref`      — the PR this coverage is about (adapter's opaque ref).
    * `head_sha`    — 40 hex chars, the exact commit covered.
    * `base_ref`    — what the net diff was taken against.
    * `net_diff_id` — `NetDiff.fingerprint(base...head_sha)`.
    * `kind`        — `:reviewed` (an approving round covered this commit),
                      `:mechanical` (the fleet produced this head from an
                      already-covered one with a provably identical
                      fingerprint — a base merge, rebase-forward, or
                      identical force-push), or `:operator` (a human
                      authorised this head explicitly).
    * `source`      — which subsystem called `record/1`.
    * `round`       — the ReviewGate round, when applicable.
    * `derived_from`— for a `:mechanical` row, the id of the row whose
                      fingerprint match justified it. Required for
                      `:mechanical`, must be nil otherwise.
    * `covered_at`  — when coverage was established.

  ## Append-only

  No update or destroy action exists. A correction is a new row, never an
  edit — the table is the audit trail the design doc argues for.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Reviews,
    data_layer: AshSqlite.DataLayer

  @kinds ~w(reviewed mechanical operator)a
  @sources ~w(review_gate review_patrol external_review watchdog cli)a
  @head_sha_format ~r/^[0-9a-f]{40}$/

  sqlite do
    table "review_coverage"
    repo Arbiter.Repo

    custom_indexes do
      index [:task_id]
    end
  end

  actions do
    create :record do
      primary? true

      accept [
        :task_id,
        :mr_ref,
        :head_sha,
        :base_ref,
        :net_diff_id,
        :kind,
        :source,
        :round,
        :derived_from,
        :covered_at
      ]
    end

    read :read do
      primary? true
    end
  end

  validations do
    # §3.1: a :mechanical row names its parent; every other kind must not.
    validate fn changeset, _context ->
      kind = Ash.Changeset.get_attribute(changeset, :kind)
      derived_from = Ash.Changeset.get_attribute(changeset, :derived_from)

      cond do
        kind == :mechanical and is_nil(derived_from) ->
          {:error, field: :derived_from, message: "is required for a :mechanical row"}

        kind != :mechanical and not is_nil(derived_from) ->
          {:error, field: :derived_from, message: "must be nil unless kind is :mechanical"}

        true ->
          :ok
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "The authoring task, always."
    end

    attribute :mr_ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
      description "The PR this coverage is about (opaque adapter ref)."
    end

    attribute :head_sha, :string do
      allow_nil? false
      public? true
      constraints match: @head_sha_format
      description "40 hex chars, the exact commit covered."
    end

    attribute :base_ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
      description "What the net diff was taken against."
    end

    attribute :net_diff_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
      description "NetDiff.fingerprint(base...head_sha)."
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: @sources
    end

    attribute :round, :integer do
      public? true
      description "ReviewGate round, when applicable."
    end

    attribute :derived_from, :uuid do
      public? true
      description "For a :mechanical row, the covered entry whose fingerprint matched."
    end

    attribute :covered_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
  end

  identities do
    # §3.3/acceptance: Coverage.record/1 is idempotent on {mr_ref, head_sha, kind}.
    identity :mr_head_kind, [:mr_ref, :head_sha, :kind], eager_check?: true
  end

  @doc "All valid kind atoms."
  def kinds, do: @kinds

  @doc "All valid source atoms."
  def sources, do: @sources
end
