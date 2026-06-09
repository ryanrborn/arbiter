defmodule Arbiter.Beads.Issue.Changes.InheritTrackerType do
  @moduledoc """
  If `tracker_type` wasn't passed explicitly on create, default it from the
  workspace's config (`config["tracker"]["type"]`). If the workspace doesn't
  specify one, the attribute's default (`:none`) stands.

  Caller can always override by passing `tracker_type:` to the create action.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @valid ~w(none jira shortcut linear github)

  @impl true
  def change(changeset, _opts, _context) do
    # Only inherit if the caller didn't EXPLICITLY pass tracker_type.
    # The attribute has a default of :none, which means `changing_attribute?`
    # returns true even when caller didn't pass it — so we check raw params.
    explicit? =
      Map.has_key?(changeset.params, "tracker_type") or
        Map.has_key?(changeset.params, :tracker_type)

    if explicit? do
      changeset
    else
      Changeset.before_action(changeset, fn cs ->
        workspace_id = Changeset.get_attribute(cs, :workspace_id)

        case Ash.get(Arbiter.Beads.Workspace, workspace_id) do
          {:ok, workspace} ->
            inherited =
              workspace.config
              |> Map.get("tracker", %{})
              |> Map.get("type")

            if inherited in @valid do
              Changeset.force_change_attribute(
                cs,
                :tracker_type,
                String.to_existing_atom(inherited)
              )
            else
              cs
            end

          {:error, _} ->
            cs
        end
      end)
    end
  end
end
