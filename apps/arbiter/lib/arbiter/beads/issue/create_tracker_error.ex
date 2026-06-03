defmodule Arbiter.Beads.Issue.CreateTrackerError do
  @moduledoc """
  Error returned from the `Issue.create` after-transaction hook
  (`Arbiter.Beads.Issue.Changes.CreateTracker`) when the bead was committed
  locally but the upstream tracker create failed (or the follow-up bind
  failed).

  The bead is intact in the local ledger and can be referenced by `bead_id`;
  the `reason` carries the adapter-level error (typically a
  `%Arbiter.Trackers.GitHub.Error{}` or sibling). The API fallback controller
  serialises this into a `tracker_upstream_create_failed` 502 response so the
  CLI can surface a clear message and exit non-zero.

  Built on `Splode.Error` so Ash propagates the struct (and its fields)
  through `Ash.Error.Unknown.UnknownError.error` without `inspect/1`-ing it
  to a string.
  """

  use Splode.Error,
    fields: [:bead_id, :tracker_type, :upstream_ref, :reason, :message],
    class: :unknown

  def message(%__MODULE__{message: msg}) when is_binary(msg), do: msg

  def message(%__MODULE__{bead_id: id, tracker_type: type, reason: reason}) do
    "bead #{id} created locally, but failed to create upstream #{type} issue: " <>
      render_reason(reason)
  end

  defp render_reason(%{message: msg}) when is_binary(msg), do: msg
  defp render_reason(reason) when is_binary(reason), do: reason
  defp render_reason(reason), do: inspect(reason)
end
