defmodule Arbiter.Beads.Issue.Changes.CreateUpstream do
  @moduledoc """
  After-transaction hook for `Issue.create`: when the bead has a tracker
  configured, mirror it into the upstream tracker and persist the returned
  ref back into `tracker_ref`.

  Skipped (no upstream call) when **any** of these hold:

    * `tracker_type == :none` — the workspace has no tracker.
    * `tracker_ref` was supplied — the caller is binding to an existing
      upstream issue (`arb create --tracker-ref N`), not creating a new one.
    * the `:skip_upstream_create` argument is `true` — explicit opt-out
      (`arb create --no-tracker`).

  Runs in an `after_transaction` hook (not `after_action`) so the bead is
  **committed before** the upstream call. That preserves the bead even when
  the upstream create fails, mirroring the `--deps` failure semantics in
  `ArbiterCli.Cmd.Create`: the local resource is durable, the failure is
  surfaced to the caller, and a follow-up `arb update --tracker-ref` can
  re-link the bead without orphaning anything.

  On a successful upstream create the returned ref is persisted to the bead
  via a second `Ash.update` (the after-transaction phase has already
  committed, so we're outside the original transaction). On failure the
  hook returns `{:ok, issue}` *but* stashes a structured error in the
  per-process slot returned by `last_error/0` — the bead is durable, the
  action result is success, and the controller picks the stash up after
  `Ash.create` returns and renders the 502 + bead body that lets the CLI
  exit non-zero with a useful message.

  We use a process-dict side channel rather than `{:error, term}` because
  Ash wraps unrecognised error terms in `Ash.Error.Unknown.UnknownError`,
  which mangles the shape into a string and discards the kind/bead_id
  fields the controller needs to render a structured 502 response.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Beads.Workspace
  alias Arbiter.Trackers

  @pdict_key {__MODULE__, :last_error}

  @doc """
  Returns and clears the upstream-create error stashed by the most recent
  `Issue.create` call on this process. `nil` when none was stashed (the
  common case: tracker not configured, or the upstream create succeeded).
  """
  @spec last_error() :: map() | nil
  def last_error, do: Process.delete(@pdict_key)

  @impl true
  def change(changeset, _opts, _context) do
    skip = Ash.Changeset.get_argument(changeset, :skip_upstream_create) == true

    # Clear any stale error from a prior create on this process (defensive —
    # the controller drains via `last_error/0`, but a re-used process in
    # tests/scripts could otherwise see a stale entry).
    Process.delete(@pdict_key)

    Ash.Changeset.after_transaction(changeset, fn _cs, result ->
      with {:ok, issue} <- result,
           true <- needs_upstream_create?(issue, skip) do
        do_create(issue)
      else
        false ->
          result

        other ->
          other
      end
    end)
  end

  defp needs_upstream_create?(_issue, true), do: false
  defp needs_upstream_create?(%{tracker_type: :none}, _), do: false
  defp needs_upstream_create?(%{tracker_ref: ref}, _) when is_binary(ref) and ref != "", do: false
  defp needs_upstream_create?(_issue, _skip), do: true

  defp do_create(issue) do
    case load_workspace(issue.workspace_id) do
      nil ->
        # Bead was created without a resolvable workspace — can't dispatch.
        Logger.warning("CreateUpstream: bead=#{issue.id} has no resolvable workspace; skipping")

        {:ok, issue}

      workspace ->
        attrs = build_attrs(issue)

        case Trackers.create_for_workspace(workspace, attrs) do
          {:ok, ref} ->
            persist_ref(issue, ref)

          {:error, :not_supported} ->
            # Tracker type doesn't support outbound create (e.g. :none, or a
            # stub adapter). Local-only bead; not a failure.
            {:ok, issue}

          {:error, reason} ->
            Logger.warning(
              "CreateUpstream: failed to create upstream for bead=#{issue.id} " <>
                "tracker=#{issue.tracker_type}: #{inspect(reason)}"
            )

            stash_error(%{
              kind: :upstream_create_failed,
              bead_id: issue.id,
              tracker_type: issue.tracker_type,
              reason: reason,
              message: upstream_error_message(issue, reason)
            })

            # Return the bead so the action result is `{:ok, issue}` — the
            # caller drains `last_error/0` to decide whether to surface the
            # failure as a 502 / non-zero exit.
            {:ok, issue}
        end
    end
  end

  defp stash_error(err) do
    Process.put(@pdict_key, err)
    :ok
  end

  defp build_attrs(issue) do
    %{}
    |> put_if_present(:title, issue.title)
    |> put_if_present(:description, issue.description)
    |> put_if_present(:assignee, issue.assignee)
    |> put_if_present(:status, issue.status)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp persist_ref(issue, ref) do
    case Ash.update(issue, %{tracker_ref: ref}, action: :update) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, reason} ->
        # Upstream issue was created but we couldn't persist the ref back.
        # This is the rare "orphan" case — surface clearly so the user can
        # manually bind with `arb update --tracker-ref`.
        Logger.error(
          "CreateUpstream: created upstream ref=#{ref} for bead=#{issue.id} but " <>
            "failed to persist tracker_ref: #{inspect(reason)}"
        )

        stash_error(%{
          kind: :upstream_ref_persist_failed,
          bead_id: issue.id,
          tracker_ref: ref,
          tracker_type: issue.tracker_type,
          reason: reason,
          message:
            "created upstream issue #{ref} but failed to link it to bead #{issue.id}; " <>
              "re-link with `arb issue update #{issue.id} --tracker-ref #{ref}`"
        })

        {:ok, issue}
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp upstream_error_message(issue, %{message: msg}) when is_binary(msg) do
    "bead #{issue.id} created locally but upstream #{issue.tracker_type} create failed: #{msg}"
  end

  defp upstream_error_message(issue, reason) do
    "bead #{issue.id} created locally but upstream #{issue.tracker_type} create failed: " <>
      inspect(reason)
  end
end
