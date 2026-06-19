defmodule Arbiter.PolecatNotificationTest do
  # DataCase (async: false → shared sandbox) so the polecat process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when it
  # writes the lifecycle notification.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "completing a polecat records an enriched notification AND broadcasts it" do
    ws = uniq("ws-notify")
    bead_id = uniq("bd-notify")

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws))

    {:ok, pid} = Polecat.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.complete(pid, :done)

    # PubSub broadcast arrived...
    assert_receive {:new_message, %{kind: :notification, from_ref: ^bead_id}}, 1_000

    # ...and a durable notification row was written with the completion shape.
    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.kind == :notification
    assert notification.from_ref == bead_id
    assert notification.subject == "#{bead_id} completed"
    assert notification.body =~ "completed in"
  end

  test "failing a polecat records a failure notification with the exit code" do
    ws = uniq("ws-fail")
    bead_id = uniq("bd-fail")

    {:ok, pid} = Polecat.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.report(pid, :exit_status, 137)
    :ok = Polecat.fail(pid, :boom)

    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.subject == "#{bead_id} failed"
    assert notification.body =~ "failed after"
    assert notification.body =~ "exit code 137"
  end

  test "parking a polecat to :awaiting records an awaiting-review notification" do
    ws = uniq("ws-await")
    bead_id = uniq("bd-await")

    {:ok, pid} = Polecat.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :submit)
    :ok = Polecat.report(pid, :mr_ref, "!42")
    :ok = Polecat.await(pid, :review)

    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.subject == "#{bead_id} awaiting review"
    assert notification.body =~ "opened MR !42"
    assert notification.body =~ "awaiting review"
  end

  test "auto-posts are suppressed when admiral_notifications is disabled" do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: uniq("quiet-ws"),
        config: %{"admiral_notifications" => false}
      })

    bead_id = uniq("bd-quiet")

    {:ok, pid} = Polecat.start(bead_id: bead_id, repo: "arbiter", workspace_id: workspace.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.complete(pid, :done)

    assert Message.recent_notifications(10, workspace_id: workspace.id) == []
  end
end
