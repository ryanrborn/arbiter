defmodule Arbiter.Messages.MessageTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message

  @ws "ws-msg-test"

  describe "create/validation" do
    test "creates a notification with minimal attrs" do
      {:ok, m} =
        Ash.create(Message, %{kind: :notification, workspace_id: @ws, body: "polecat done"})

      assert m.kind == :notification
      assert m.workspace_id == @ws
      assert m.body == "polecat done"
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

  describe "send_mail/1 + inbox/2 + mark_read/1" do
    test "mailbox messages addressed to a bead show up unread in the inbox" do
      {:ok, _m} =
        Message.send_mail(%{
          workspace_id: @ws,
          from_ref: "admiral",
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

    test "inbox excludes notifications and other beads' mail" do
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

    test "an acolyte's completion addressed to the admiral shows in the admiral inbox" do
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

  describe "recent_notifications/2" do
    test "returns newest notifications first, scoped to workspace" do
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "first"})
      {:ok, _} = Message.notify(%{workspace_id: @ws, body: "second"})
      {:ok, _} = Message.notify(%{workspace_id: "other-ws", body: "elsewhere"})

      bodies = Message.recent_notifications(10, workspace_id: @ws) |> Enum.map(& &1.body)
      assert bodies == ["second", "first"]
    end
  end
end
