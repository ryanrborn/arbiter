defmodule Arbiter.Mergers.ReviewedSha do
  @moduledoc """
  The reviewed-SHA baseline for an automated merge (bd-dxgris / #1493).

  An automated merger acts on a review verdict that was computed against one
  specific commit. If the branch advances between approval and merge, merging
  "whatever head the forge reports at call time" merges commits no reviewer
  ever saw. Both captured production incidents (`vs-cgh54b`/!177,
  `vs-a7w5g9`/!179) went through the Watchdog's retry loop, where the window
  between the approving poll and a successful merge is measured in *polls*,
  not milliseconds — plenty of room for a push to land.

  This module holds the two decisions that make up the guard, so the Watchdog
  and the MergeQueue can't drift apart on them:

    * `latch/3` — pin the baseline at the head SHA observed on the *first*
      poll that reported the MR approved, and hold it across the whole
      approval episode.
    * `check/2` — compare that baseline against the head observed on the poll
      that is about to merge, and decide whether to merge (and with what
      `expected_sha`) or refuse.

  ## Why latch rather than use the head of the merging poll

  Passing the merging poll's own head as `expected_sha` closes only the
  milliseconds between that poll and the merge call. It does not close the
  incident: a forge that does not dismiss stale approvals on push (GitHub
  without "dismiss stale reviews", GitLab without `reset_approvals_on_push`)
  keeps reporting `approved: true` after a push, so poll N+20 would happily
  merge a head the reviewer never saw — and the `expected_sha` would match,
  because it was read from that same poll. Latching at first approval is what
  makes the guard bind.

  Conversely, a forge that *does* dismiss the approval on push makes the MR
  report `approved: false`, which drops the latch (`latch/3`) so the next
  genuine approval re-latches against the new head. That is the intended
  recovery path: a re-review clears the guard, nothing else does.

  ## No reviewed SHA available

  `check(nil, _)` returns `{:ok, nil}` — merge **unguarded**. Refusing would be
  the safer-sounding default, but it strands every legitimate merge on a path
  that has no review baseline to offer: the `Direct` (local, no-MR) strategy,
  where `open/4` has already performed the merge and `merge/2` is a no-op; and
  any adapter whose `get/1` does not surface a head SHA. Those paths are not
  the race this guard exists to close — the race needs a forge MR whose head
  can advance under a recorded approval, and every such path *does* produce a
  baseline (the latch, at minimum). So "no baseline" here means "no MR head to
  race against", not "review skipped", and refusing it would trade a real
  correctness win for a fleet-wide stall. The `nil` is threaded explicitly
  through `Arbiter.Mergers.Merger.merge/2`'s **required** second argument, so
  an unguarded merge is always a deliberate, visible choice at the call site
  rather than an omitted argument.
  """

  @typedoc "A stale-baseline refusal: the reviewed SHA and the head that superseded it."
  @type stale :: {:stale_reviewed_sha, String.t(), String.t()}

  @doc """
  Update the latched reviewed baseline from one poll observation.

  `approved?` is the MR's approval state on this poll and `head_sha` its head
  commit. Returns the baseline to carry forward: the first approved head for
  the duration of the approval episode, or `nil` once the approval lapses.
  """
  @spec latch(String.t() | nil, boolean(), String.t() | nil) :: String.t() | nil
  def latch(_current, approved?, _head_sha) when approved? != true, do: nil
  def latch(current, true, _head_sha) when is_binary(current) and current != "", do: current
  def latch(_current, true, head_sha) when is_binary(head_sha) and head_sha != "", do: head_sha
  def latch(_current, true, _head_sha), do: nil

  @doc """
  Decide whether a merge may proceed, given the reviewed baseline and the head
  observed on the poll that is about to merge.

  Returns `{:ok, expected_sha}` — the value to hand to
  `c:Arbiter.Mergers.Merger.merge/2`, which the forge then enforces
  atomically — or `{:error, t:stale/0}` when the branch has advanced past the
  reviewed commit.
  """
  @spec check(String.t() | nil, String.t() | nil) :: {:ok, String.t() | nil} | {:error, stale()}
  def check(reviewed, _head) when not is_binary(reviewed) or reviewed == "", do: {:ok, nil}

  def check(reviewed, head) when is_binary(head) and head != "" and head != reviewed,
    do: {:error, {:stale_reviewed_sha, reviewed, head}}

  def check(reviewed, _head), do: {:ok, reviewed}
end
