defmodule GtElixir.Beads.DependencyTest do
  use GtElixir.DataCase, async: false

  alias GtElixir.Beads.Dependency
  alias GtElixir.Beads.Issue
  alias GtElixir.Beads.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "dep-ws", prefix: "dep"})
    {:ok, a} = Ash.create(Issue, %{title: "issue A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "issue B", workspace_id: ws.id})
    {:ok, c} = Ash.create(Issue, %{title: "issue C", workspace_id: ws.id})
    {:ok, ws: ws, a: a, b: b, c: c}
  end

  describe "create/2" do
    test "creates a :blocks edge with minimal attrs", %{a: a, b: b} do
      {:ok, dep} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      assert dep.from_issue_id == a.id
      assert dep.to_issue_id == b.id
      assert dep.type == :blocks
      assert dep.created_by == nil
      assert %DateTime{} = dep.created_at

      # notes not passed → persisted as NULL. The attribute's `default ""` is an
      # Ash-level default that applies when reading via the changeset, but the
      # DB column is nullable and the insert sends NULL when no value is given.
      # Caller-supplied notes round-trip via the explicit-pass test below.
      reloaded = Ash.get!(Dependency, dep.id)
      assert reloaded.notes in [nil, ""]
    end

    test "creates with notes (Markdown) and created_by", %{a: a, b: b} do
      notes = "# why\n\nbecause **#{a.id}** writes the schema first."

      {:ok, dep} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on,
          notes: notes,
          created_by: "mayor"
        })

      assert dep.notes == notes
      assert dep.created_by == "mayor"
    end

    test "accepts each of the 5 type enums", %{a: a, b: b, c: c} do
      # Five distinct edges so the unique index doesn't collide. We rotate
      # endpoints/types so every combination is unique on (from, to, type).
      types_and_endpoints = [
        {:blocks, a.id, b.id},
        {:depends_on, a.id, c.id},
        {:relates_to, b.id, c.id},
        {:discovered_from, b.id, a.id},
        {:parent_of, c.id, a.id}
      ]

      for {type, from_id, to_id} <- types_and_endpoints do
        assert {:ok, dep} =
                 Ash.create(Dependency, %{
                   from_issue_id: from_id,
                   to_issue_id: to_id,
                   type: type
                 }),
               "expected to create dep with type #{type}"

        assert dep.type == type
      end
    end

    test "rejects an invalid type", %{a: a, b: b} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Dependency, %{
                 from_issue_id: a.id,
                 to_issue_id: b.id,
                 type: :rumor
               })
    end

    test "rejects self-reference (from == to)", %{a: a} do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Dependency, %{
                 from_issue_id: a.id,
                 to_issue_id: a.id,
                 type: :blocks
               })

      assert err |> Exception.message() |> String.contains?("cannot depend on itself")
    end

    test "rejects duplicate (from, to, type)", %{a: a, b: b} do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Dependency, %{
                 from_issue_id: a.id,
                 to_issue_id: b.id,
                 type: :blocks
               })
    end

    test "allows same (from, to) with different types", %{a: a, b: b} do
      {:ok, _b1} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      assert {:ok, _r1} =
               Ash.create(Dependency, %{
                 from_issue_id: a.id,
                 to_issue_id: b.id,
                 type: :relates_to
               })
    end

    test "rejects nonexistent from_issue_id (FK violation)", %{b: b} do
      assert {:error, _} =
               Ash.create(Dependency, %{
                 from_issue_id: "dep-nope00",
                 to_issue_id: b.id,
                 type: :blocks
               })
    end

    test "rejects nonexistent to_issue_id (FK violation)", %{a: a} do
      assert {:error, _} =
               Ash.create(Dependency, %{
                 from_issue_id: a.id,
                 to_issue_id: "dep-nope00",
                 type: :blocks
               })
    end

    test "rejects missing required fields", %{a: a, b: b} do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Dependency, %{})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Dependency, %{from_issue_id: a.id, type: :blocks})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Dependency, %{to_issue_id: b.id, type: :blocks})
    end
  end

  describe "helpers" do
    test "types/0 returns all 5 type atoms" do
      assert Dependency.types() ==
               ~w(blocks depends_on relates_to discovered_from parent_of)a
    end
  end

  describe "Issue.ready/0" do
    test "an issue with no deps is ready", %{a: a, b: b, c: c} do
      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.equal?(ready_ids, MapSet.new([a.id, b.id, c.id]))
    end

    test "an issue blocked by an open :depends_on target is NOT ready", %{a: a, b: b} do
      # a depends_on b; b is open ⇒ a is blocked.
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(ready_ids, a.id)
      assert MapSet.member?(ready_ids, b.id)
    end

    test "closing the dep target makes the dependent ready", %{a: a, b: b} do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on
        })

      refute Issue.ready() |> Enum.any?(&(&1.id == a.id))

      {:ok, _closed_b} = Ash.update(b, %{}, action: :close)

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids, a.id)
      # b is closed → not in ready set
      refute MapSet.member?(ready_ids, b.id)
    end

    test ":blocks edge gates readiness on the from side too", %{a: a, b: b} do
      # a blocks b ⇒ from a's perspective, a has an open :blocks edge whose
      # target b is open ⇒ a is NOT ready by the readiness rule.
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(ready_ids, a.id)
    end

    test ":relates_to does NOT gate readiness", %{a: a, b: b} do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :relates_to
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids, a.id)
      assert MapSet.member?(ready_ids, b.id)
    end

    test ":discovered_from and :parent_of do NOT gate readiness", %{a: a, b: b, c: c} do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :discovered_from
        })

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: c.id,
          type: :parent_of
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids, a.id)
    end

    test "closed issues are excluded from ready", %{a: a} do
      {:ok, _closed_a} = Ash.update(a, %{}, action: :close)
      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(ready_ids, a.id)
    end

    test "in_progress issues are excluded from ready (only :open counts)", %{a: a} do
      {:ok, _ip} = Ash.update(a, %{status: :in_progress})
      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(ready_ids, a.id)
    end

    test "multiple gating deps: dependent is ready only when ALL targets closed",
         %{a: a, b: b, c: c} do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on
        })

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: c.id,
          type: :blocks
        })

      refute Issue.ready() |> Enum.any?(&(&1.id == a.id))

      {:ok, _} = Ash.update(b, %{}, action: :close)
      # Still blocked on c
      refute Issue.ready() |> Enum.any?(&(&1.id == a.id))

      {:ok, _} = Ash.update(c, %{}, action: :close)
      assert Issue.ready() |> Enum.any?(&(&1.id == a.id))
    end
  end
end
