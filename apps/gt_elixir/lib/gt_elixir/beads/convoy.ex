defmodule GtElixir.Beads.Convoy do
  @moduledoc """
  A Convoy is a batch of related Issues tracked together. Equivalent to a
  `hq-cv-...` convoy in gas-town: opens with N tracked work items, closes when
  the batch is done.

  ## ID format

  `"{workspace.prefix}-cv-{short_id}"` (e.g. `"bd-cv-3o8abc"`). Mirrors gas-town's
  convention of segmenting convoy IDs with a `cv-` infix so they're recognizable
  at a glance.

  ## Lifecycle modes

  * `:system_managed` (default) — convoy auto-closes when ALL tracked issues
    are closed AND there is at least one tracked issue. Triggered by an
    `after_action` hook on `Issue.close`.
  * `:owned` — user controls explicitly. Auto-close is suppressed even if all
    members are closed. The user calls `Ash.update(convoy, ..., action: :close)`
    when they decide it's done.

  ## Aggregates

  * `total_issues` — count of all tracked issues
  * `closed_issues` — count of tracked issues with status :closed

  Caller composes a "progress" map: `%{closed: closed_issues, total: total_issues}`.

  ## Status FSM

  Simple: `:open` → `:closed`. No reopen (yet). A closed convoy is terminal.
  """

  use Ash.Resource,
    otp_app: :gt_elixir,
    domain: GtElixir.Beads,
    data_layer: AshPostgres.DataLayer

  @lifecycles ~w(system_managed owned)a
  @statuses ~w(open closed)a

  postgres do
    table "convoys"
    repo GtElixir.Repo

    references do
      reference :workspace, on_delete: :restrict
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :lifecycle, :workspace_id]
      change {GtElixir.Beads.Convoy.Changes.GenerateId, []}
    end

    update :update do
      primary? true
      accept [:title, :lifecycle]
      require_atomic? false
    end

    update :close do
      require_atomic? false
      argument :reason, :string

      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
      change {GtElixir.Beads.Convoy.Changes.SetClosedReason, []}
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      # Allow uppercase to match Issue's pattern; see Issue.ex for rationale.
      constraints match: ~r/^[a-z][a-zA-Z0-9]*-cv-[a-zA-Z0-9]+$/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: @statuses
    end

    attribute :lifecycle, :atom do
      allow_nil? false
      public? true
      default :system_managed
      constraints one_of: @lifecycles
    end

    attribute :closed_at, :utc_datetime_usec, public?: true
    attribute :closed_reason, :string, public?: true, constraints: [max_length: 500]

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, GtElixir.Beads.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    has_many :memberships, GtElixir.Beads.ConvoyMembership do
      destination_attribute :convoy_id
      public? true
    end

    many_to_many :issues, GtElixir.Beads.Issue do
      through GtElixir.Beads.ConvoyMembership
      source_attribute_on_join_resource :convoy_id
      destination_attribute_on_join_resource :issue_id
      public? true
    end
  end

  aggregates do
    count :total_issues, :issues

    count :closed_issues, :issues do
      filter expr(status == :closed)
    end
  end

  @doc "List of valid lifecycle atoms."
  def lifecycles, do: @lifecycles

  @doc "List of valid status atoms."
  def statuses, do: @statuses

  @doc """
  If `convoy` is system-managed, still open, and all its (≥1) tracked issues
  are closed, close the convoy with reason "all members closed". Returns the
  (possibly updated) Convoy. Safe to call repeatedly.
  """
  def maybe_auto_close(convoy) do
    convoy = Ash.load!(convoy, [:total_issues, :closed_issues])

    cond do
      convoy.lifecycle != :system_managed ->
        convoy

      convoy.status != :open ->
        convoy

      convoy.total_issues == 0 ->
        convoy

      convoy.closed_issues < convoy.total_issues ->
        convoy

      true ->
        {:ok, closed} =
          Ash.update(convoy, %{reason: "all members closed"}, action: :close)

        closed
    end
  end

  @doc """
  Walk this issue's convoys and call `maybe_auto_close/1` on each.
  Intended for the `after_action` hook on `Issue.close`.
  """
  def maybe_auto_close_for_issue(issue) do
    issue = Ash.load!(issue, :convoys)
    Enum.each(issue.convoys, &maybe_auto_close/1)
    :ok
  end
end
