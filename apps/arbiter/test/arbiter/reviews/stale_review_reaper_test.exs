defmodule Arbiter.Reviews.StaleReviewReaperTest do
  @moduledoc """
  bd-4vc2bo: an `ExternalReview` record whose reviewer process died mid-flight
  is left `status: "running"` forever — nothing ever reaps it. These tests
  drive `StaleReviewReaper.reap/1` synchronously against a fixed clock and
  assert stale `running` records are transitioned to `failed`, while records
  that are recent, already terminal, or explicitly exempt are left alone.
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Reviews.{Record, StaleReviewReaper}
  alias Arbiter.Tasks.Workspace

  defp uniq_prefix, do: "sr" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp ws do
    {:ok, workspace} =
      Ash.create(Workspace, %{name: "reaper-ws-" <> uniq_prefix(), prefix: uniq_prefix()})

    workspace
  end

  defp record(ws, attrs) do
    {:ok, rec} =
      Ash.create(
        Record,
        Map.merge(
          %{
            pr_ref: "octo/widget#1",
            workspace_id: ws.id,
            strategy: "github",
            status: :running,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    rec
  end

  test "transitions a running record past the deadline to failed" do
    workspace = ws()

    stale =
      record(workspace, %{started_at: DateTime.add(DateTime.utc_now(), -5, :hour)})

    assert :ok = StaleReviewReaper.reap(timeout_ms: 60 * 60_000)

    updated = Ash.get!(Record, stale.id)
    assert updated.status == :failed
    assert updated.failure_stage == "reaper"
    assert updated.failure_reason =~ "no progress"
    refute is_nil(updated.completed_at)
  end

  test "leaves a running record inside the deadline untouched" do
    workspace = ws()

    fresh =
      record(workspace, %{started_at: DateTime.add(DateTime.utc_now(), -5, :minute)})

    assert :ok = StaleReviewReaper.reap(timeout_ms: 60 * 60_000)

    updated = Ash.get!(Record, fresh.id)
    assert updated.status == :running
    assert is_nil(updated.failure_stage)
  end

  test "never touches an already-terminal record" do
    workspace = ws()

    completed =
      record(workspace, %{
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -5, :hour),
        completed_at: DateTime.add(DateTime.utc_now(), -4, :hour)
      })

    assert :ok = StaleReviewReaper.reap(timeout_ms: 60 * 60_000)

    updated = Ash.get!(Record, completed.id)
    assert updated.status == :completed
    assert is_nil(updated.failure_stage)
  end
end
