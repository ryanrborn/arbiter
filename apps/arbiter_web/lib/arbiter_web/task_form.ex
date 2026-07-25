defmodule ArbiterWeb.TaskForm do
  @moduledoc """
  Shared form plumbing for the dashboard's issue create/edit forms
  (`TaskIndexLive` create, `TaskDetailLive` edit).

  Both forms post plain string params and write through the `Issue` `:create` /
  `:update` actions, so the same three concerns recur: option lists for the
  enum-ish selects, coercing `""` back to `nil`, and flattening an Ash error
  into one line for the inline error slot. They live here rather than being
  copy-pasted so the two forms can't drift apart.
  """

  alias Arbiter.Tasks.Issue

  @doc "Select options for `priority` (0 = most urgent)."
  def priority_options do
    Enum.map(0..4, fn p -> {"P#{p}#{priority_hint(p)}", to_string(p)} end)
  end

  defp priority_hint(0), do: " — drop everything"
  defp priority_hint(1), do: " — urgent"
  defp priority_hint(2), do: " — normal"
  defp priority_hint(3), do: " — low"
  defp priority_hint(4), do: " — someday"

  @doc "Select options for `difficulty` (nullable; blank means unset → routed as D2)."
  def difficulty_options do
    [{"— unset —", ""}] ++
      Enum.map(0..4, fn d -> {"D#{d} — #{difficulty_hint(d)}", to_string(d)} end)
  end

  defp difficulty_hint(0), do: "trivial"
  defp difficulty_hint(1), do: "simple"
  defp difficulty_hint(2), do: "moderate"
  defp difficulty_hint(3), do: "hard"
  defp difficulty_hint(4), do: "extreme"

  @doc "Select options for `issue_type`, drawn from the resource itself."
  def issue_type_options do
    Enum.map(Issue.issue_types(), &{to_string(&1), to_string(&1)})
  end

  @doc """
  Statuses an operator may set from the edit form. `:closed` is deliberately
  absent — the `:update` action's `GuardStatus` change refuses transitions
  involving `:closed`, which is what the separate close action (with a reason)
  is for.
  """
  def editable_status_options, do: [{"open", "open"}, {"in_progress", "in_progress"}]

  @doc """
  The value to render for `key`, preferring what the operator last submitted.

  LiveView only preserves the currently-focused input across a re-render; every
  other field is morphed back to whatever the server rendered. So on a rejected
  submit the form re-renders from the stashed params, falling back to `default`
  (blank for a create form, the persisted attribute for an edit form) when the
  field wasn't submitted at all. A submitted `""` is kept as `""` — the
  operator deliberately cleared it.
  """
  def value(params, key, default \\ "") do
    case Map.get(params || %{}, key) do
      nil -> default
      submitted -> submitted
    end
  end

  @doc "Trim a form string, returning `nil` for blank."
  def trimmed(nil), do: nil

  def trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def trimmed(value), do: value

  @doc """
  Parse an integer form field. Returns `{:ok, integer | nil}` for a blank or
  well-formed value, `:error` otherwise — a select can only produce values we
  rendered, but a hand-rolled POST can produce anything.
  """
  def parse_int(value) do
    case trimmed(value) do
      nil ->
        {:ok, nil}

      str ->
        case Integer.parse(str) do
          {int, ""} -> {:ok, int}
          _ -> :error
        end
    end
  end

  @doc "Flatten an Ash error (or any exception) into a single inline message."
  def error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map_join("; ", &Exception.message/1)
  end

  def error_message(err) when is_exception(err), do: Exception.message(err)
  def error_message(other), do: inspect(other)
end
