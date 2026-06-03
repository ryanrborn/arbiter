defmodule Arbiter.Trackers.None do
  @moduledoc """
  The null tracker. Used when a workspace (or a specific bead) has no external
  tracker — the bead ledger is the only source of truth.

  All callbacks succeed as no-ops. `fetch/1` returns an empty map (there is
  nothing to fetch). `link_for/1` returns an empty string (no URL).
  `parse_ref/1` always returns `:error` (we never own a ref).
  `list_transitions/1` returns the full bead status set, since the bead ledger
  has no externally-imposed restrictions.

  `create/1` is the one explicit error: a bead with `tracker_type: :none` has
  no upstream to create against, so attempting to mirror it is a programming
  error. The outbound create-hook is responsible for skipping `:none` beads
  before reaching this adapter.
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
  def create(_attrs), do: {:error, :no_tracker_configured}
end
