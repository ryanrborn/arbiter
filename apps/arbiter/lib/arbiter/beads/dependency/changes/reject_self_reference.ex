defmodule Arbiter.Beads.Dependency.Changes.RejectSelfReference do
  @moduledoc """
  Prevents creating a Dependency where `from_issue_id == to_issue_id`. A bead
  cannot depend on itself — that would either be a logic bug at the call site or
  a malformed import. Either way, fail loudly at create-time rather than persist
  a nonsense edge.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      from_id = Changeset.get_attribute(cs, :from_issue_id)
      to_id = Changeset.get_attribute(cs, :to_issue_id)

      if not is_nil(from_id) and from_id == to_id do
        Changeset.add_error(cs,
          field: :to_issue_id,
          message: "an issue cannot depend on itself"
        )
      else
        cs
      end
    end)
  end
end
