defmodule Arbiter.Beads.Convoy.Changes.GenerateId do
  @moduledoc """
  Generates a Convoy's string PK on create as `"{workspace.prefix}-cv-{short_id}"`.

  Mirrors `Arbiter.Beads.Issue.Changes.GenerateId` but with a `cv-` infix so
  convoy IDs are distinguishable from issue IDs at a glance.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      workspace_id = Changeset.get_attribute(cs, :workspace_id)

      case Ash.get(Arbiter.Beads.Workspace, workspace_id) do
        {:ok, workspace} ->
          short_id = generate_short_id()
          id = "#{workspace.prefix}-cv-#{short_id}"
          Changeset.force_change_attribute(cs, :id, id)

        {:error, _} ->
          Changeset.add_error(cs, field: :workspace_id, message: "workspace not found")
      end
    end)
  end

  defp generate_short_id do
    :crypto.strong_rand_bytes(5)
    |> :binary.decode_unsigned()
    |> Integer.to_string(36)
    |> String.downcase()
    |> String.slice(0, 6)
    |> String.pad_leading(6, "0")
  end
end
