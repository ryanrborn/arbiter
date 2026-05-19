defmodule GtElixir.Beads.Issue.Changes.GenerateId do
  @moduledoc """
  Generates the Issue's string PK on create as `"{workspace.prefix}-{short_id}"`.

  short_id: 6 chars base36 random (about 2 billion possible values; collision
  probability is negligible at any realistic scale).

  Load order:
  1. Resolve the workspace from `workspace_id` argument.
  2. Read its `prefix` attribute.
  3. Generate a fresh short_id.
  4. Force the `:id` attribute.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      workspace_id = Changeset.get_attribute(cs, :workspace_id)

      case Ash.get(GtElixir.Beads.Workspace, workspace_id) do
        {:ok, workspace} ->
          short_id = generate_short_id()
          id = "#{workspace.prefix}-#{short_id}"
          Changeset.force_change_attribute(cs, :id, id)

        {:error, _} ->
          Changeset.add_error(cs,
            field: :workspace_id,
            message: "workspace not found"
          )
      end
    end)
  end

  defp generate_short_id do
    # 5 bytes = 40 bits = max 1_099_511_627_776, base36 length 7-8.
    # Slice to 6 chars (still ~2B possibilities), lowercase, left-pad.
    :crypto.strong_rand_bytes(5)
    |> :binary.decode_unsigned()
    |> Integer.to_string(36)
    |> String.downcase()
    |> String.slice(0, 6)
    |> String.pad_leading(6, "0")
  end
end
