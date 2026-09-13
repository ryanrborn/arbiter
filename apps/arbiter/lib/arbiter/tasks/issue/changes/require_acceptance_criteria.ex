defmodule Arbiter.Tasks.Issue.Changes.RequireAcceptanceCriteria do
  @moduledoc """
  bd-7mbrlg: refuses `:promote_to_ready` for a `bug`/`feature`/`chore` with
  blank `acceptance` unless the caller passes a non-blank `acceptance_waived`
  reason (persisted onto the issue). `task`, `decision`, and `epic` are
  exempt — see `Arbiter.Tasks.Issue.gated_type?/1`.

  D0 (trivial) work is auto-waived: a single-file, fully-specified change has
  no meaningful acceptance criteria to write, so this records a standard
  reason instead of forcing a rubber-stamp waiver on every D0 ticket.

  Already-refined issues skip the check entirely — re-promoting (a no-op
  write) must stay idempotent even if the issue was refined before this rule
  existed and has no ACs and no waiver on file.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Arbiter.Tasks.Issue

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    issue = changeset.data

    cond do
      issue.refined ->
        changeset

      not Issue.gated_type?(issue.issue_type) ->
        changeset

      present?(issue.acceptance) ->
        changeset

      issue.difficulty == 0 ->
        Changeset.force_change_attribute(
          changeset,
          :acceptance_waived,
          "D0 (trivial) — auto-waived, no acceptance criteria required"
        )

      true ->
        case waiver_reason(changeset) do
          nil ->
            Changeset.add_error(changeset,
              field: :acceptance,
              message:
                "Cannot promote a #{issue.issue_type} to Ready with no acceptance criteria. " <>
                  "Add `acceptance` to the task, or pass `acceptance_waived: \"<reason>\"` " <>
                  "to promote anyway."
            )

          reason ->
            Changeset.force_change_attribute(changeset, :acceptance_waived, reason)
        end
    end
  end

  defp waiver_reason(changeset) do
    case Changeset.get_argument(changeset, :acceptance_waived) do
      reason when is_binary(reason) -> if present?(reason), do: String.trim(reason)
      _ -> nil
    end
  end

  defp present?(nil), do: false
  defp present?(str) when is_binary(str), do: String.trim(str) != ""
end
