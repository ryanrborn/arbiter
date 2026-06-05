defmodule Arbiter.Trackers.None do
  @moduledoc """
  The null tracker. Used when a workspace (or a specific bead) has no external
  tracker — the bead ledger is the only source of truth.

  All callbacks succeed as no-ops. `fetch/1` returns an empty map (there is
  nothing to fetch). `link_for/1` returns an empty string (no URL).
  `parse_ref/1` always returns `:error` (we never own a ref).
  `list_transitions/1` returns the full bead status set, since the bead ledger
  has no externally-imposed restrictions. `list_open/1` returns
  `{:error, :not_supported}` because there is no upstream backlog to list —
  callers (e.g. `arb list --tracker`) treat that as "render local beads only".
  `create/1` returns `{:error, :not_supported}` so the `arb create` upstream
  hook short-circuits for untracked workspaces (callers should never reach
  this — they skip outbound create when `tracker_type == :none`).
  """

  @behaviour Arbiter.Trackers.Tracker

  @impl true
  def fetch(_ref), do: {:ok, %{}}

  @impl true
  def transition(_ref, _status), do: :ok

  @impl true
  def update_fields(_ref, _fields), do: :ok

  @impl true
  def link_for(_ref), do: ""

  @impl true
  def parse_ref(_s), do: :error

  @impl true
  def list_transitions(_ref), do: {:ok, [:open, :in_progress, :closed]}

  @impl true
  def list_open(_opts), do: {:error, :not_supported}

  @impl true
  def create(_attrs), do: {:error, :not_supported}

  @impl true
  def current_user, do: {:error, :not_supported}

  @impl true
  def assignees(_), do: []

  @impl true
  def issue_status(_), do: :open

  @impl true
  def extract_title(_), do: "(no title)"

  @impl true
  def extract_description(_), do: ""
end
