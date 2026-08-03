defmodule Arbiter.Messages.MessageTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message

  @ws "ws-msg-test"

  describe "create/validation" do
    test "creates a notification with minimal attrs" do
      {:ok, m} =
        Ash.create(Message, %{kind: :notification, workspace_id: @ws, body: "worker done"})

      assert m.kind == :notification
      assert m.workspace_id == @ws
      assert m.body == "worker done"
      assert m.to_ref == nil
      assert m.read_at == nil
      assert %DateTime{} = m.inserted_at
    end

    test "rejects an unknown kind" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Message, %{kind: :bogus, workspace_id: @ws, body: "x"})
    end

    test "rejects a missing workspace_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Message, %{kind: :notification, body: "x"})
    end
  end

  describe "PubSub broadcast on create" do
    test "broadcasts {:new_message, message} on the workspace topic" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(@ws))

      {:ok, m} = Message.notify(%{workspace_id: @ws, subject: "done", body: "bd-x complete"})

      assert_receive {:new_message, received}
      assert received.id == m.id
      assert received.kind == :notification
    end
  end

  describe "PubSub broadcast on mark_read" do
    test "broadcasts {:message_read, message} on the workspace topic" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(@ws))

      {:ok, m} =
        Message.send_mail(%{
          workspace_id: @ws,
          from_ref: "bd-soren",
          to_ref: "admiral",
          kind: :completion,
          subject: "bd-soren complete",
          body: "done"
        })

      # Drain the :new_message that fires on create so the assert_receive below
      # is unambiguous.
      assert_receive {:new_message, _}

      {:ok, read} = Message.mark_read(m)

      assert_receive {:message_read, received}
      assert received.id == read.id
      assert %DateTime{} = received.read_at
    end
  end

  describe "send_mail/1 + inbox/2 + mark_read/1" do
    test "mailbox messages addressed to a task show up unread in the inbox" do
      {:ok, _m} =
        Message.send_mail(%{
          workspace_id: @ws,
          from_ref: "coordinator",
          to_ref: "bd-soren",
          body: "check the API contract"
        })

      [msg] = Message.inbox("bd-soren", workspace_id: @ws)
      assert msg.body == "check the API contract"
      assert msg.read_at == nil

      {:ok, read} = Message.mark_read(msg)
      assert %DateTime{} = read.read_at

      assert Message.inbox("bd-soren", workspace_id: @ws) == []
    end

    test "inbox excludes notifications and other tasks' mail" do
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "noise"})
      {:ok, _} = Message.send_mail(%{workspace_id: @ws, to_ref: "bd-other", body: "not yours"})

      {:ok, _} =
        Message.send_mail(%{workspace_id: @ws, to_ref: "bd-me", kind: :flag, body: "heads up"})

      ids = Message.inbox("bd-me", workspace_id: @ws) |> Enum.map(& &1.body)
      assert ids == ["heads up"]
    end

    test "direction and flag are mailbox-family kinds" do
      assert :direction in Message.mailbox_kinds()
      assert :flag in Message.mailbox_kinds()
      refute :notification in Message.mailbox_kinds()
    end
  end

  describe "admiral mailbox kinds" do
    test "completion/failure/escalation/info are valid and mailbox-family" do
      for kind <- ~w(completion failure escalation info)a do
        assert kind in Message.kinds()
        assert kind in Message.mailbox_kinds()
      end
    end

    test "an worker's completion addressed to the admiral shows in the admiral inbox" do
      {:ok, _} =
        Ash.create(Message, %{
          kind: :completion,
          from_ref: "bd-soren",
          to_ref: "admiral",
          directive_ref: "bd-soren",
          subject: "GitLab adapter complete",
          body: "All 19 tests green.",
          workspace_id: @ws
        })

      [msg] = Message.inbox("admiral", workspace_id: @ws)
      assert msg.kind == :completion
      assert msg.directive_ref == "bd-soren"
      assert msg.subject == "GitLab adapter complete"
    end

    test "directive_ref persists and defaults to nil" do
      {:ok, with_ref} =
        Ash.create(Message, %{
          kind: :info,
          to_ref: "admiral",
          body: "x",
          directive_ref: "bd-1",
          workspace_id: @ws
        })

      {:ok, without_ref} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "y", workspace_id: @ws})

      assert with_ref.directive_ref == "bd-1"
      assert without_ref.directive_ref == nil
    end
  end

  describe "coordinator mailbox literal + admiral→coordinator compat" do
    test "coordinator_ref/0 is the canonical literal; coordinator_refs/0 covers both" do
      assert Message.coordinator_ref() == "coordinator"
      assert "coordinator" in Message.coordinator_refs()
      assert "admiral" in Message.coordinator_refs()
    end

    test "ref_variants/1 expands either coordinator literal, passes others through" do
      assert Enum.sort(Message.ref_variants("coordinator")) == ["admiral", "coordinator"]
      assert Enum.sort(Message.ref_variants("admiral")) == ["admiral", "coordinator"]
      assert Message.ref_variants("bd-soren") == ["bd-soren"]
    end

    test "inbox/2 dual-reads: a legacy \"admiral\" row is visible under \"coordinator\"" do
      {:ok, _} =
        Ash.create(Message, %{
          kind: :completion,
          from_ref: "bd-soren",
          to_ref: "admiral",
          body: "legacy row",
          workspace_id: @ws
        })

      assert [%{body: "legacy row"}] = Message.inbox("coordinator", workspace_id: @ws)
    end

    test "inbox/2 dual-reads: a new \"coordinator\" row is visible under \"admiral\"" do
      {:ok, _} =
        Message.send_mail(%{
          kind: :completion,
          from_ref: "bd-soren",
          to_ref: "coordinator",
          body: "new row",
          workspace_id: @ws
        })

      assert [%{body: "new row"}] = Message.inbox("admiral", workspace_id: @ws)
    end

    test "clear_read/2 with either coordinator literal drains both variants' read tail" do
      {:ok, legacy} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "legacy", workspace_id: @ws})

      {:ok, current} =
        Message.send_mail(%{
          to_ref: "coordinator",
          kind: :info,
          body: "current",
          workspace_id: @ws
        })

      {:ok, _} = Message.mark_read(legacy)
      {:ok, _} = Message.mark_read(current)

      assert {:ok, 2, 0, 0} = Message.clear_read("coordinator", workspace_id: @ws)
      assert Message.inbox("coordinator", workspace_id: @ws) == []
    end

    test "clear_all/2 with either coordinator literal removes both variants" do
      {:ok, _} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "legacy", workspace_id: @ws})

      {:ok, _} =
        Message.send_mail(%{
          to_ref: "coordinator",
          kind: :info,
          body: "current",
          workspace_id: @ws
        })

      assert {:ok, _, _, 0} = Message.clear_all("admiral", workspace_id: @ws)
      assert Message.inbox("coordinator", workspace_id: @ws) == []
    end

    test "broadcast_new fires the inbox SSE event for the new coordinator literal" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(@ws))

      {:ok, _} =
        Message.send_mail(%{
          to_ref: "coordinator",
          kind: :escalation,
          from_ref: "bd-soren",
          body: "needs a decision",
          workspace_id: @ws
        })

      assert_receive {:event, %{topic: "inbox"}}
    end
  end

  describe "PubSub broadcast on clear_read/2" do
    test "broadcasts {:mailbox_cleared, workspace_id} on the workspace topic" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(@ws))

      {:ok, m} =
        Message.send_mail(%{workspace_id: @ws, to_ref: "admiral", kind: :info, body: "to clear"})

      assert_receive {:new_message, _}
      {:ok, _} = Message.mark_read(m)
      assert_receive {:message_read, _}

      Message.clear_read("admiral", workspace_id: @ws)

      assert_receive {:mailbox_cleared, @ws}
    end

    test "broadcasts once per distinct workspace_id" do
      ws2 = "ws-msg-test-2"
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(@ws))
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws2))

      {:ok, m1} =
        Message.send_mail(%{workspace_id: @ws, to_ref: "admiral", kind: :info, body: "ws1"})

      {:ok, m2} =
        Message.send_mail(%{workspace_id: ws2, to_ref: "admiral", kind: :info, body: "ws2"})

      {:ok, _} = Message.mark_read(m1)
      {:ok, _} = Message.mark_read(m2)

      # Drain :new_message and :message_read noise.
      assert_receive {:new_message, _}
      assert_receive {:new_message, _}
      assert_receive {:message_read, _}
      assert_receive {:message_read, _}

      Message.clear_read("admiral")

      received =
        for _ <- 1..2 do
          receive do
            {:mailbox_cleared, ws} -> ws
          after
            500 -> nil
          end
        end

      assert Enum.sort(received) == Enum.sort([@ws, ws2])
    end
  end

  describe "PubSub broadcast on clear_all/2" do
    test "broadcasts {:mailbox_cleared, workspace_id} on the workspace topic" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(@ws))

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: @ws,
          to_ref: "admiral",
          kind: :info,
          body: "unread too"
        })

      assert_receive {:new_message, _}

      Message.clear_all("admiral", workspace_id: @ws)

      assert_receive {:mailbox_cleared, @ws}
    end
  end

  describe "clear_read/2" do
    test "clears (soft) only already-read mail addressed to to_ref, keeping unread" do
      {:ok, read} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "read", workspace_id: @ws})

      {:ok, _} = Message.mark_read(read)

      {:ok, unread} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "unread", workspace_id: @ws})

      assert Message.clear_read("admiral") == {:ok, 1, 0, 1}

      # Soft: the read row is retained (cleared_at stamped), not destroyed.
      assert {:ok, %Message{cleared_at: cleared_at}} = Ash.get(Message, read.id)
      assert %DateTime{} = cleared_at
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, unread.id)
    end

    test "leaves other recipients' outstanding mail untouched" do
      {:ok, mine} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "a", workspace_id: @ws})

      {:ok, theirs} =
        Ash.create(Message, %{kind: :info, to_ref: "bd-9", body: "b", workspace_id: @ws})

      {:ok, _} = Message.mark_read(mine)
      {:ok, _} = Message.mark_read(theirs)

      assert Message.clear_read("admiral") == {:ok, 1, 0, 0}
      # theirs stays outstanding (read, not cleared).
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, theirs.id)
    end
  end

  describe "three states: unread / outstanding / cleared" do
    test "a fresh mailbox message is unread (read_at nil, cleared_at nil)" do
      {:ok, m} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "fresh", workspace_id: @ws})

      assert m.read_at == nil
      assert m.cleared_at == nil
      assert [%{body: "fresh"}] = Message.inbox("admiral", workspace_id: @ws)
      assert Message.outstanding("admiral", workspace_id: @ws) == []
    end

    test "reading a body stamps read_at → outstanding; cleared_at stays nil" do
      {:ok, m} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "seen", workspace_id: @ws})

      {:ok, read} = Message.mark_read(m)
      assert %DateTime{} = read.read_at
      assert read.cleared_at == nil

      # It drops out of the unread queue but is now outstanding.
      assert Message.inbox("admiral", workspace_id: @ws) == []
      assert [%{body: "seen"}] = Message.outstanding("admiral", workspace_id: @ws)
    end

    test "mark_cleared stamps cleared_at → cleared; leaves neither queue" do
      {:ok, m} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "done", workspace_id: @ws})

      {:ok, _} = Message.mark_read(m)
      {:ok, cleared} = Message.mark_cleared(m)

      assert %DateTime{} = cleared.cleared_at
      assert Message.inbox("admiral", workspace_id: @ws) == []
      assert Message.outstanding("admiral", workspace_id: @ws) == []
      # The row is retained and still fetchable — clear is soft, not destructive.
      assert {:ok, %Message{body: "done"}} = Ash.get(Message, m.id)
    end

    test "mark_cleared is idempotent, mirroring mark_read" do
      {:ok, m} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "x", workspace_id: @ws})

      {:ok, first} = Message.mark_cleared(m)
      {:ok, second} = Message.mark_cleared(first)

      assert %DateTime{} = first.cleared_at
      assert %DateTime{} = second.cleared_at
    end

    test "mark_cleared accepts an id" do
      {:ok, m} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "byid", workspace_id: @ws})

      {:ok, cleared} = Message.mark_cleared(m.id)
      assert %DateTime{} = cleared.cleared_at
    end
  end

  describe "cleared_at scoped to @mailbox_kinds (notifications unaffected)" do
    test "a notification cannot be cleared — cleared_at is rejected" do
      {:ok, n} = Message.notify(%{workspace_id: @ws, body: "event"})

      assert {:error, %Ash.Error.Invalid{}} = Message.mark_cleared(n)
      # Unchanged: still fetchable, still unconsumed.
      assert {:ok, %Message{read_at: nil, cleared_at: nil}} = Ash.get(Message, n.id)
    end

    test "clear_all leaves notifications untouched" do
      {:ok, n} = Message.notify(%{workspace_id: @ws, body: "hum"})

      {:ok, _} =
        Message.send_mail(%{to_ref: "admiral", kind: :info, body: "mail", workspace_id: @ws})

      Message.clear_all("admiral", workspace_id: @ws)

      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, n.id)
    end
  end

  describe "clear_read/2 is soft (stamps cleared_at, retains rows)" do
    test "outstanding rows become cleared but remain retrievable" do
      {:ok, read} =
        Ash.create(Message, %{
          kind: :info,
          to_ref: "admiral",
          body: "outstanding",
          workspace_id: @ws
        })

      {:ok, _} = Message.mark_read(read)

      {:ok, unread} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "pending", workspace_id: @ws})

      # 1 cleared, 0 unread cleared, 1 remaining unread.
      assert Message.clear_read("admiral") == {:ok, 1, 0, 1}

      # The row is retained (soft), with cleared_at stamped.
      assert {:ok, %Message{cleared_at: cleared_at}} = Ash.get(Message, read.id)
      assert %DateTime{} = cleared_at
      # Unread pending row untouched.
      assert {:ok, %Message{read_at: nil, cleared_at: nil}} = Ash.get(Message, unread.id)
      # Cleared drops out of both queues.
      assert Message.inbox("admiral", workspace_id: @ws) |> Enum.map(& &1.body) == ["pending"]
      assert Message.outstanding("admiral", workspace_id: @ws) == []
    end
  end

  describe "clear_all/2 is soft (stamps cleared_at on read + unread)" do
    test "every mailbox row addressed to to_ref is cleared but retained" do
      {:ok, read} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "r", workspace_id: @ws})

      {:ok, _} = Message.mark_read(read)

      {:ok, unread} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "u", workspace_id: @ws})

      assert {:ok, 1, 1, 0} = Message.clear_all("admiral", workspace_id: @ws)

      assert {:ok, %Message{cleared_at: c1}} = Ash.get(Message, read.id)
      assert {:ok, %Message{cleared_at: c2}} = Ash.get(Message, unread.id)
      assert %DateTime{} = c1
      assert %DateTime{} = c2
      assert Message.inbox("admiral", workspace_id: @ws) == []
      assert Message.outstanding("admiral", workspace_id: @ws) == []
    end
  end

  describe "hard_purge/2 is the only destructive path" do
    test "destroys cleared rows; leaves unread and outstanding intact" do
      {:ok, cleared} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "gone", workspace_id: @ws})

      {:ok, _} = Message.mark_read(cleared)
      {:ok, _} = Message.mark_cleared(cleared)

      {:ok, outstanding} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "kept-out", workspace_id: @ws})

      {:ok, _} = Message.mark_read(outstanding)

      {:ok, unread} =
        Ash.create(Message, %{
          kind: :info,
          to_ref: "admiral",
          body: "kept-unread",
          workspace_id: @ws
        })

      assert {:ok, 1} = Message.hard_purge("admiral", workspace_id: @ws)

      # Only the cleared row is destroyed.
      assert {:error, _} = Ash.get(Message, cleared.id)
      assert {:ok, _} = Ash.get(Message, outstanding.id)
      assert {:ok, _} = Ash.get(Message, unread.id)
    end

    test "clear_read never destroys — a cleared message is still retrievable afterwards" do
      {:ok, m} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "keep", workspace_id: @ws})

      {:ok, _} = Message.mark_read(m)
      {:ok, _, _, _} = Message.clear_read("admiral", workspace_id: @ws)

      # Soft clear retained the row — hard_purge is the only path that removes it.
      assert {:ok, %Message{}} = Ash.get(Message, m.id)
    end
  end

  describe "backfill invariant (migration 20260803200744)" do
    test "cleared_at = read_at leaves no historical read row 'outstanding'" do
      # A pre-migration read row is shaped exactly like today's "outstanding"
      # (read_at set, cleared_at nil). Seed both a read and an unread row, then
      # run the migration's backfill statement verbatim.
      {:ok, historical_read} =
        Ash.create(Message, %{kind: :info, to_ref: "admiral", body: "old-read", workspace_id: @ws})

      {:ok, _} = Message.mark_read(historical_read)

      {:ok, historical_unread} =
        Ash.create(Message, %{
          kind: :info,
          to_ref: "admiral",
          body: "old-unread",
          workspace_id: @ws
        })

      # Verbatim backfill from priv/repo/migrations/20260803200744_add_cleared_at_to_messages.exs
      Arbiter.Repo.query!("UPDATE messages SET cleared_at = read_at WHERE read_at IS NOT NULL")

      {:ok, read_after} = Ash.get(Message, historical_read.id)
      {:ok, unread_after} = Ash.get(Message, historical_unread.id)

      # The read row is now cleared, with cleared_at == read_at.
      assert read_after.cleared_at == read_after.read_at
      # The unread row is untouched — still pending.
      assert unread_after.read_at == nil
      assert unread_after.cleared_at == nil

      # The decisive invariant: NO historical row lands in the outstanding queue.
      assert Message.outstanding("admiral", workspace_id: @ws) == []
    end
  end

  describe "recent_notifications/2" do
    test "returns newest notifications first, scoped to workspace" do
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "first"})
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "second"})
      {:ok, _} = Message.notify(%{workspace_id: "other-ws", body: "elsewhere"})

      bodies = Message.recent_notifications(10, workspace_id: @ws) |> Enum.map(& &1.body)
      assert bodies == ["second", "first"]
    end
  end

  describe "recent_escalations/2" do
    test "returns newest escalations first, read and unread alike, scoped to workspace" do
      {:ok, _} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          workspace_id: @ws,
          subject: "ReviewGate: changes requested for bd-aaa",
          body: "first"
        })

      {:ok, second} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          workspace_id: @ws,
          subject: "ReviewGate: review inconclusive for bd-bbb",
          body: "second"
        })

      {:ok, _} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          workspace_id: "other-ws",
          body: "elsewhere"
        })

      # Acknowledging an escalation must NOT drop it from the view (unlike inbox/2).
      {:ok, _} = Message.mark_read(second)

      bodies = Message.recent_escalations(10, workspace_id: @ws) |> Enum.map(& &1.body)
      assert bodies == ["second", "first"]
    end

    test "ignores non-escalation mailbox kinds" do
      {:ok, _} =
        Message.send_mail(%{kind: :info, to_ref: "admiral", workspace_id: @ws, body: "fyi"})

      {:ok, _} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          workspace_id: @ws,
          body: "needs attention"
        })

      bodies = Message.recent_escalations(10, workspace_id: @ws) |> Enum.map(& &1.body)
      assert bodies == ["needs attention"]
    end
  end
end
