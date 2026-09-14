defmodule Arbiter.Tasks.ReviewParkTest do
  @moduledoc """
  The park row as the escalation claim (bd-9zuvbh, invariant I3 of design
  #1635 §5.1: one escalation per episode).

  The claim lives in the row rather than in the worker's memory for the reason
  `ReviewPatrol.claim_review_cap_escalation/1` does: a worker that restarts, or
  a gate that reports its terminal twice, must not buy a second page. The
  episode's reset condition is the guard's own — here, the park reason changing,
  or a human clearing the park and the gate reaching the same terminal again.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, ReviewPark, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "park-unit-#{System.unique_integer([:positive])}",
        prefix: "pu"
      })

    {:ok, task} = Ash.create(Issue, %{title: "parkable", workspace_id: ws.id})
    {:ok, task} = Ash.update(task, %{status: :in_progress})

    %{ws: ws, task: task}
  end

  test "the first park claims the episode", %{task: task} do
    assert {:ok, :claimed, parked} = ReviewPark.park(task.id, :inconclusive)
    assert parked.review_park_reason == "inconclusive"
    assert %DateTime{} = parked.review_parked_at
    assert ReviewPark.parked?(parked)
  end

  test "re-parking for the same reason does not re-claim", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)

    assert {:ok, :already_parked, _} = ReviewPark.park(task.id, :inconclusive)
  end

  test "a different reason is a new episode", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)

    assert {:ok, :claimed, parked} = ReviewPark.park(task.id, :reviewer_timeout)
    assert parked.review_park_reason == "reviewer_timeout"
  end

  test "clearing and re-reaching the same terminal is a new episode", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)
    {:ok, cleared} = ReviewPark.clear(task.id, :review_rerun)
    refute ReviewPark.parked?(cleared)

    assert {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)
  end

  test "clearing an unparked task is a no-op success", %{task: task} do
    assert {:ok, unchanged} = ReviewPark.clear(task.id, :review_rerun)
    refute ReviewPark.parked?(unchanged)
  end

  test "the park does not move the task out of :in_progress", %{task: task} do
    {:ok, :claimed, parked} = ReviewPark.park(task.id, :verdict_guard_exhausted)

    # A flag, not a status: Tasks.Claim and the board must keep seeing live work.
    assert parked.status == :in_progress
  end

  test "every reason renders a subject phrase and an explanation" do
    for {reason, _} <- ReviewPark.reasons() do
      assert is_binary(ReviewPark.subject_phrase(reason))
      assert ReviewPark.explain(reason) != ""
      refute ReviewPark.explain(reason) =~ "terminal no-verdict state ("
    end
  end

  test "an unknown reason renders rather than raising" do
    assert ReviewPark.explain(:something_new) =~ "something_new"
    assert ReviewPark.subject_phrase("not_an_atom_anywhere") == "not_an_atom_anywhere"
  end
end
