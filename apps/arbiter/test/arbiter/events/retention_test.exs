defmodule Arbiter.Events.RetentionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.{Record, Retention}
  require Ash.Query

  defp insert!(inserted_at) do
    {:ok, record} =
      Record
      |> Ash.Changeset.for_create(:create, %{
        workspace_id: "ws-retention",
        topic: "worker_done",
        payload: %{},
        occurred_at: inserted_at
      })
      |> Ash.create()

    # inserted_at is a create_timestamp (always "now") — backdate it directly
    # so the test can simulate an old row without sleeping.
    record
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Arbiter.Repo.update!()

    record
  end

  test "sweep/1 deletes rows older than retention_days and keeps the rest" do
    old = insert!(DateTime.add(DateTime.utc_now(), -10, :day))
    recent = insert!(DateTime.add(DateTime.utc_now(), -1, :hour))

    Retention.sweep(retention_days: 7)

    remaining_ids =
      Record
      |> Ash.Query.filter(workspace_id == "ws-retention")
      |> Ash.read!()
      |> Enum.map(& &1.seq)

    refute old.seq in remaining_ids
    assert recent.seq in remaining_ids
  end
end
