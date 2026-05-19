defmodule GtElixir.Trackers.None do
  @moduledoc """
  The null tracker. Used when a workspace (or a specific bead) has no external
  tracker — the bead ledger is the only source of truth.

  All callbacks succeed as no-ops. `fetch/1` returns an empty map (there is
  nothing to fetch). `link_for/1` returns an empty string (no URL).
  `parse_ref/1` always returns `:error` (we never own a ref).
  `list_transitions/1` returns the full bead status set, since the bead ledger
  has no externally-imposed restrictions.
  """

  @behaviour GtElixir.Trackers.Tracker

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
end
