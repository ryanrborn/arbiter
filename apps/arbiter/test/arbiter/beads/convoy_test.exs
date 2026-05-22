defmodule Arbiter.Beads.ConvoyTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Convoy
  alias Arbiter.Beads.ConvoyMembership
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "convoy-test", prefix: "ct"})
    {:ok, ws: ws}
  end

  describe "create/2" do
    test "succeeds with minimal valid attrs; id has '{prefix}-cv-' shape", %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "batch one", workspace_id: ws.id})

      assert String.starts_with?(c.id, "ct-cv-")
      assert String.length(c.id) == 3 + 3 + 6, "id pattern '{prefix}-cv-{6}': #{c.id}"
      assert c.title == "batch one"
      assert c.status == :open
      assert c.lifecycle == :system_managed
      assert c.closed_at == nil
      assert c.closed_reason == nil
    end

    test "accepts :owned lifecycle", %{ws: ws} do
      {:ok, c} =
        Ash.create(Convoy, %{title: "user-owned", lifecycle: :owned, workspace_id: ws.id})

      assert c.lifecycle == :owned
    end

    test "rejects invalid lifecycle", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Convoy, %{
                 title: "bogus",
                 lifecycle: :neither,
                 workspace_id: ws.id
               })
    end

    test "rejects missing title", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Convoy, %{workspace_id: ws.id})
    end

    test "rejects missing workspace_id" do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Convoy, %{title: "orphan"})
    end
  end

  describe "membership + aggregates" do
    setup %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "batch", workspace_id: ws.id})
      {:ok, i1} = Ash.create(Issue, %{title: "i1", workspace_id: ws.id})
      {:ok, i2} = Ash.create(Issue, %{title: "i2", workspace_id: ws.id})
      {:ok, i3} = Ash.create(Issue, %{title: "i3", workspace_id: ws.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i2.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i3.id})
      {:ok, c: c, i1: i1, i2: i2, i3: i3}
    end

    test "total_issues + closed_issues aggregates reflect current state", %{c: c, i1: i1, i2: i2} do
      c_loaded = Ash.load!(c, [:total_issues, :closed_issues])
      assert c_loaded.total_issues == 3
      assert c_loaded.closed_issues == 0

      {:ok, _} = Ash.update(i1, %{}, action: :close)
      {:ok, _} = Ash.update(i2, %{}, action: :close)

      c_loaded = Ash.load!(c, [:total_issues, :closed_issues])
      assert c_loaded.total_issues == 3
      assert c_loaded.closed_issues == 2
    end

    test "rejects duplicate membership (same convoy + same issue)", %{c: c, i1: i1} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
    end
  end

  describe "system_managed auto-close" do
    setup %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "auto", workspace_id: ws.id})
      {:ok, i1} = Ash.create(Issue, %{title: "i1", workspace_id: ws.id})
      {:ok, i2} = Ash.create(Issue, %{title: "i2", workspace_id: ws.id})
      {:ok, i3} = Ash.create(Issue, %{title: "i3", workspace_id: ws.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i2.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i3.id})
      {:ok, c: c, i1: i1, i2: i2, i3: i3}
    end

    test "convoy stays open while some issues remain open", %{c: c, i1: i1, i2: i2} do
      {:ok, _} = Ash.update(i1, %{}, action: :close)
      {:ok, _} = Ash.update(i2, %{}, action: :close)

      c_after = Ash.get!(Convoy, c.id)
      assert c_after.status == :open
      assert c_after.closed_at == nil
    end

    test "convoy auto-closes when the last issue is closed (acceptance)",
         %{c: c, i1: i1, i2: i2, i3: i3} do
      {:ok, _} = Ash.update(i1, %{}, action: :close)
      {:ok, _} = Ash.update(i2, %{}, action: :close)

      c_mid = Ash.get!(Convoy, c.id)
      assert c_mid.status == :open

      {:ok, _} = Ash.update(i3, %{}, action: :close)

      c_after = Ash.get!(Convoy, c.id)
      assert c_after.status == :closed
      assert %DateTime{} = c_after.closed_at
      assert c_after.closed_reason == "all members closed"
    end

    test "empty system-managed convoy doesn't auto-close on Convoy.maybe_auto_close/1", %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "empty", workspace_id: ws.id})

      result = Convoy.maybe_auto_close(c)
      assert result.status == :open
    end
  end

  describe ":owned lifecycle does NOT auto-close" do
    setup %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "owned", lifecycle: :owned, workspace_id: ws.id})
      {:ok, i1} = Ash.create(Issue, %{title: "i1", workspace_id: ws.id})
      {:ok, i2} = Ash.create(Issue, %{title: "i2", workspace_id: ws.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i2.id})
      {:ok, c: c, i1: i1, i2: i2}
    end

    test "remains open even when all members are closed", %{c: c, i1: i1, i2: i2} do
      {:ok, _} = Ash.update(i1, %{}, action: :close)
      {:ok, _} = Ash.update(i2, %{}, action: :close)

      c_after = Ash.get!(Convoy, c.id)
      assert c_after.status == :open
      assert c_after.closed_at == nil
    end

    test "user can explicitly close via :close action", %{c: c} do
      {:ok, closed} = Ash.update(c, %{reason: "user wraps it up"}, action: :close)
      assert closed.status == :closed
      assert closed.closed_reason == "user wraps it up"
      assert %DateTime{} = closed.closed_at
    end
  end

  describe ":close action" do
    test "sets status + closed_at + closed_reason", %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "manual", workspace_id: ws.id})

      {:ok, closed} = Ash.update(c, %{reason: "wrapping up"}, action: :close)
      assert closed.status == :closed
      assert closed.closed_reason == "wrapping up"
      assert %DateTime{} = closed.closed_at
    end

    test "without reason, closed_reason remains nil", %{ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "no-reason", workspace_id: ws.id})

      {:ok, closed} = Ash.update(c, %{}, action: :close)
      assert closed.status == :closed
      assert closed.closed_reason == nil
    end
  end

  describe "enums helpers" do
    test "lifecycles/0" do
      assert Convoy.lifecycles() == ~w(system_managed owned)a
    end

    test "statuses/0" do
      assert Convoy.statuses() == ~w(open closed)a
    end
  end
end
