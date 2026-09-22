defmodule Arbiter.Tasks.Issue.Changes.InheritTrackerType do
  @moduledoc """
  If `tracker_type` wasn't passed explicitly on create, default it from the
  workspace's config (`config["tracker"]["type"]`). If the workspace doesn't
  specify one, the attribute's default (`:none`) stands.

  ## Children of a tracker-linked parent (#1973)

  When the create names a `parent_id` whose parent is linked to a ticket, the
  default comes from the *parent's* linkage instead, per the workspace's
  `tracker.child_policy` (or the action's `tracker_child_policy` argument, which
  outranks it — a refine session passes `:context_only`):

    * `:context_only` (default) — `tracker_type: :none`, and the parent's ticket
      is copied into `tracker_context_type`/`tracker_context_ref`. Nothing is
      minted upstream (`CreateUpstream` skips `:none`), but workers still read
      the ticket's acceptance criteria, and the branch/PR key is the parent's.
    * `:inherit_parent` — the child is bound to the parent's ticket
      (`tracker_type`/`tracker_ref` copied). Nothing is minted (`CreateUpstream`
      skips a task that already has a `tracker_ref`).
    * `:mint` — the workspace default above, exactly as before #1973.

  "Linked" means a real `tracker_ref` (non-`:none` type, non-blank ref). A parent
  that is itself context-only passes its context down, so a grandchild does not
  mint either — under `:inherit_parent` too, since there is no ticket to bind.
  A parent with neither, or a `parent_id` that doesn't resolve, leaves the
  workspace default in place.

  Caller can always override by passing `tracker_type:` to the create action —
  and passing `tracker_ref:` (binding an existing ticket) also opts out of the
  parent default. An explicit `tracker_context_type`/`_ref` is never overwritten.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Ash.Changeset

  @valid ~w(none jira shortcut linear github gitlab)

  @impl true
  def change(changeset, _opts, _context) do
    # Only inherit if the caller didn't EXPLICITLY pass tracker_type.
    # The attribute has a default of :none, which means `changing_attribute?`
    # returns true even when caller didn't pass it — so we check raw params.
    if explicit?(changeset, :tracker_type) do
      changeset
    else
      Changeset.before_action(changeset, fn cs ->
        case Ash.get(Workspace, Changeset.get_attribute(cs, :workspace_id)) do
          {:ok, workspace} -> apply_default(cs, workspace)
          {:error, _} -> cs
        end
      end)
    end
  end

  defp apply_default(cs, workspace) do
    with false <- binds_ticket?(cs),
         {kind, type, ref} <- parent_linkage(Changeset.get_argument(cs, :parent_id)),
         policy when policy != :mint <- policy(cs, workspace) do
      apply_parent_linkage(cs, policy, kind, type, ref)
    else
      _ -> inherit_workspace_type(cs, workspace)
    end
  end

  defp apply_parent_linkage(cs, :inherit_parent, :ticket, type, ref) do
    cs
    |> Changeset.force_change_attribute(:tracker_type, type)
    |> Changeset.force_change_attribute(:tracker_ref, ref)
  end

  # `:context_only`, and `:inherit_parent` under a parent that only has context.
  defp apply_parent_linkage(cs, _policy, _kind, type, ref) do
    cs = Changeset.force_change_attribute(cs, :tracker_type, :none)

    if explicit?(cs, :tracker_context_type) or explicit?(cs, :tracker_context_ref) do
      cs
    else
      cs
      |> Changeset.force_change_attribute(:tracker_context_type, type)
      |> Changeset.force_change_attribute(:tracker_context_ref, ref)
    end
  end

  defp policy(cs, workspace) do
    Changeset.get_argument(cs, :tracker_child_policy) ||
      Workspace.tracker_child_policy(workspace)
  end

  # `{:ticket, type, ref}` for a parent bound to a ticket, `{:context, type, ref}`
  # for a context-only parent, `nil` for an untracked or unresolvable one.
  defp parent_linkage(parent_id) when is_binary(parent_id) and parent_id != "" do
    case Ash.get(Issue, parent_id) do
      {:ok, %Issue{} = parent} -> linkage_of(parent)
      _ -> nil
    end
  end

  defp parent_linkage(_parent_id), do: nil

  defp linkage_of(%Issue{tracker_type: type, tracker_ref: ref} = parent) do
    cond do
      linked?(type, ref) ->
        {:ticket, type, ref}

      linked?(parent.tracker_context_type, parent.tracker_context_ref) ->
        {:context, parent.tracker_context_type, parent.tracker_context_ref}

      true ->
        nil
    end
  end

  defp linked?(type, ref), do: type not in [nil, :none] and is_binary(ref) and ref != ""

  defp inherit_workspace_type(cs, workspace) do
    inherited = get_in(workspace.config || %{}, ["tracker", "type"])

    if inherited in @valid do
      Changeset.force_change_attribute(cs, :tracker_type, String.to_existing_atom(inherited))
    else
      cs
    end
  end

  defp binds_ticket?(cs) do
    case Changeset.get_attribute(cs, :tracker_ref) do
      ref when is_binary(ref) -> String.trim(ref) != ""
      _ -> false
    end
  end

  defp explicit?(changeset, key) do
    Map.has_key?(changeset.params, to_string(key)) or Map.has_key?(changeset.params, key)
  end
end
