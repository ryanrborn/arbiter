defmodule Arbiter.WorkerNotificationTest do
  # DataCase (async: false → shared sandbox) so the worker process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when it
  # writes the lifecycle notification.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "completing a worker records an enriched notification AND broadcasts it" do
    ws = uniq("ws-notify")
    bead_id = uniq("bd-notify")

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws))

    {:ok, pid} = Worker.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    # PubSub broadcast arrived...
    assert_receive {:new_message, %{kind: :notification, from_ref: ^bead_id}}, 1_000

    # ...and a durable notification row was written with the completion shape.
    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.kind == :notification
    assert notification.from_ref == bead_id
    assert notification.subject == "#{bead_id} completed"
    assert notification.body =~ "completed in"
  end

  test "failing a worker records a failure notification with the exit code" do
    ws = uniq("ws-fail")
    bead_id = uniq("bd-fail")

    {:ok, pid} = Worker.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :exit_status, 137)
    :ok = Worker.fail(pid, :boom)

    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.subject == "#{bead_id} failed"
    assert notification.body =~ "failed after"
    assert notification.body =~ "exit code 137"
  end

  test "parking a worker to :awaiting records an awaiting-review notification" do
    ws = uniq("ws-await")
    bead_id = uniq("bd-await")

    {:ok, pid} = Worker.start(bead_id: bead_id, repo: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :submit)
    :ok = Worker.report(pid, :mr_ref, "!42")
    :ok = Worker.await(pid, :review)

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

    {:ok, pid} = Worker.start(bead_id: bead_id, repo: "arbiter", workspace_id: workspace.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    assert Message.recent_notifications(10, workspace_id: workspace.id) == []
  end
end
