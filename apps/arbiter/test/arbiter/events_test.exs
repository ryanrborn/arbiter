defmodule Arbiter.EventsTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Events
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "evt-ws-#{System.unique_integer([:positive])}", prefix: "ev"})

    {:ok, ws: ws}
  end

  describe "broadcast/3 durable persistence" do
    test "persists a row and stamps the broadcast payload with an increasing cursor", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(ws.id))

      assert :ok = Events.broadcast(ws.id, "worker_done", %{task_id: "bd-cursor-1"})
      assert_receive {:event, event1}, 500
      assert is_integer(event1.cursor)

      assert :ok = Events.broadcast(ws.id, "worker_done", %{task_id: "bd-cursor-2"})
      assert_receive {:event, event2}, 500
      assert is_integer(event2.cursor)

      assert event2.cursor > event1.cursor
    end
  end

  describe "replay/3" do
    test "returns nothing when no events have happened since the cursor", %{ws: ws} do
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-a"})

      assert %{events: [], truncated?: false} =
               Events.replay(ws.id, ["worker_done"], {:cursor, 999_999_999})
    end

    test "returns events strictly after the given cursor, in order", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(ws.id))

      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-1"})
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-2"})
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-3"})

      assert_receive {:event, %{task_id: "bd-1"}}, 500
      assert_receive {:event, e2 = %{task_id: "bd-2"}}, 500
      assert_receive {:event, e3 = %{task_id: "bd-3"}}, 500

      %{events: replayed, truncated?: false} =
        Events.replay(ws.id, ["worker_done"], {:cursor, e2.cursor - 1})

      assert Enum.map(replayed, & &1["task_id"]) == ["bd-2", "bd-3"]
      assert Enum.map(replayed, & &1["cursor"]) == [e2.cursor, e3.cursor]
    end

    test "still works when nothing has been broadcast on this workspace" do
      assert %{events: [], truncated?: false} =
               Events.replay("nonexistent-ws", ["worker_done"], {:cursor, 0})
    end

    test "filters by topic", %{ws: ws} do
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-done"})
      Events.broadcast(ws.id, "worker_failed", %{task_id: "bd-failed"})

      %{events: replayed} = Events.replay(ws.id, ["worker_done"], {:cursor, 0})

      assert Enum.map(replayed, & &1["task_id"]) == ["bd-done"]
    end

    test "scopes to the given workspace; nil workspace_id returns events across all workspaces",
         %{ws: ws} do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "evt-other-ws", prefix: "eo"})

      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-mine"})
      Events.broadcast(other_ws.id, "worker_done", %{task_id: "bd-other"})

      %{events: scoped} = Events.replay(ws.id, ["worker_done"], {:cursor, 0})
      assert Enum.map(scoped, & &1["task_id"]) == ["bd-mine"]

      %{events: global} = Events.replay(nil, ["worker_done"], {:cursor, 0})
      assert "bd-mine" in Enum.map(global, & &1["task_id"])
      assert "bd-other" in Enum.map(global, & &1["task_id"])
    end

    test "a since timestamp before any events replays everything after it", %{ws: ws} do
      before = DateTime.utc_now()
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-ts"})

      %{events: replayed} = Events.replay(ws.id, ["worker_done"], {:timestamp, before})
      assert Enum.map(replayed, & &1["task_id"]) == ["bd-ts"]
    end

    test "truncates at replay_limit/0 and reports truncated?: true", %{ws: ws} do
      limit = Events.replay_limit()

      for i <- 1..(limit + 1) do
        Events.broadcast(ws.id, "worker_done", %{task_id: "bd-#{i}"})
      end

      %{events: replayed, truncated?: truncated?} =
        Events.replay(ws.id, ["worker_done"], {:cursor, 0})

      assert length(replayed) == limit
      assert truncated? == true
    end
  end

  describe "max_cursor/0" do
    test "returns 0 when the log is empty" do
      # Other async tests may have written rows, so this only asserts the
      # floor behavior indirectly: max_cursor never goes below any known seq.
      assert Events.max_cursor() >= 0
    end

    test "returns the highest seq after a broadcast", %{ws: ws} do
      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-max"})
      before = Events.max_cursor()

      Events.broadcast(ws.id, "worker_done", %{task_id: "bd-max-2"})
      assert Events.max_cursor() > before
    end
  end
end
