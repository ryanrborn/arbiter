defmodule GtElixir.Beads.Convoy.Changes.SetClosedReason do
  @moduledoc """
  Copies the `reason` argument (passed to the `:close` action) onto the
  `:closed_reason` attribute. If `reason` wasn't passed, leaves `closed_reason`
  as-is (typically nil).
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_argument(changeset, :reason) do
      nil ->
        changeset

      "" ->
        changeset

      reason when is_binary(reason) ->
        Changeset.force_change_attribute(changeset, :closed_reason, reason)

      _ ->
        changeset
    end
  end
end
