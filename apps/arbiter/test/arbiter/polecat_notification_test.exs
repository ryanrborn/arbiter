defmodule Arbiter.PolecatNotificationTest do
  # DataCase (async: false → shared sandbox) so the polecat process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when it
  # writes the completion notification.
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Polecat

  test "completing a polecat records a notification AND broadcasts it" do
    ws = "ws-notify-#{System.unique_integer([:positive])}"
    bead_id = "bd-notify-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws))

    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.complete(pid, :done)

    # PubSub broadcast arrived...
    assert_receive {:new_message, %{kind: :notification, from_ref: ^bead_id}}, 1_000

    # ...and a durable notification row was written.
    [notification] = Message.recent_notifications(10, workspace_id: ws)
    assert notification.kind == :notification
    assert notification.from_ref == bead_id
    assert notification.subject == "#{bead_id} complete"
  end
end
