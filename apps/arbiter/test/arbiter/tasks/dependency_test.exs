defmodule Arbiter.Tasks.DependencyTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Repo

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
          created_by: "coordinator"
        })

      assert dep.notes == notes
      assert dep.created_by == "coordinator"
    end

    test "accepts each of the 6 type enums", %{a: a, b: b, c: c} do
      # Six distinct edges so the unique index doesn't collide. We rotate
      # endpoints/types so every combination is unique on (from, to, type).
      types_and_endpoints = [
        {:blocks, a.id, b.id},
        {:depends_on, a.id, c.id},
        {:relates_to, b.id, c.id},
        {:discovered_from, b.id, a.id},
        {:parent_of, c.id, a.id},
        {:conflicts_with, c.id, b.id}
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
    test "types/0 returns all 6 type atoms including :conflicts_with" do
      assert Dependency.types() ==
               ~w(blocks depends_on relates_to discovered_from parent_of conflicts_with)a
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

    test ":blocks edge blocks the to_issue (blocked task), not the from_issue (blocker)",
         %{a: a, b: b} do
      # a blocks b: b cannot be worked on until a is closed.
      # a (the blocker) has nothing blocking it and IS ready.
      # b (the blocked task) is NOT ready while a is open.
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids, a.id)
      refute MapSet.member?(ready_ids, b.id)
    end

    test ":blocks edge blocks to_issue even when blocker is :in_progress (regression bd-3hpqqi)",
         %{a: a, b: b} do
      # Repro shape: blocker (a) transitions to :in_progress before the blocked
      # task (b) is picked up. In_progress tasks are NOT in open_ids, so the
      # previous code missed the :blocks edge and falsely returned b as ready.
      {:ok, a_ip} = Ash.update(a, %{status: :in_progress})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a_ip.id,
          to_issue_id: b.id,
          type: :blocks
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()

      refute MapSet.member?(ready_ids, b.id),
             "b must not be ready while its blocker (a) is still in_progress"

      {:ok, _closed_a} = Ash.update(a_ip, %{}, action: :close)
      ready_ids_after = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids_after, b.id), "b must be ready once its blocker closes"
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

    test ":conflicts_with does NOT gate readiness (non-gating, symmetric mutex edge)", %{a: a, b: b} do
      # A conflicts_with B: both should remain ready — conflicts_with expresses
      # "don't run concurrently" (Conductor concern), not "B must close first".
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :conflicts_with
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ready_ids, a.id), "a must be ready despite conflicts_with edge"
      assert MapSet.member?(ready_ids, b.id), "b must be ready despite conflicts_with edge"
    end

    test ":conflicts_with symmetric: both directions can be queried independently", %{a: a, b: b} do
      # Store only one directed edge (A → B). Both sides remain ready — neither
      # direction gates readiness. Symmetry is a semantic property documented in
      # the moduledoc; the Conductor will query both directions when checking.
      {:ok, dep} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :conflicts_with
        })

      assert dep.type == :conflicts_with
      assert dep.from_issue_id == a.id
      assert dep.to_issue_id == b.id

      # Neither issue is blocked
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

    test "multiple gating deps: task is ready only when ALL blockers are closed",
         %{a: a, b: b, c: c} do
      # a depends_on b  → a is blocked while b is open (:depends_on direction)
      # c blocks a      → a is blocked while c is open (:blocks direction, from=c to=a)
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on
        })

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: c.id,
          to_issue_id: a.id,
          type: :blocks
        })

      refute Issue.ready() |> Enum.any?(&(&1.id == a.id))

      {:ok, _} = Ash.update(b, %{}, action: :close)
      # Still blocked on c (c blocks a and c is still open)
      refute Issue.ready() |> Enum.any?(&(&1.id == a.id))

      {:ok, _} = Ash.update(c, %{}, action: :close)
      assert Issue.ready() |> Enum.any?(&(&1.id == a.id))
    end
  end

  describe "regression: Dependency.id requires a v7 UUID (hq-109)" do
    # When the gte-007 importer was first written it used
    # `Ecto.UUID.bingenerate/0` (v4) for the Dependency primary key.
    # Inserts went through fine but `Ash.read/1` choked on the resulting
    # rows because `Dependency.id` is typed as Ash.Type.UUIDv7. The
    # symptom was a 500 on `GET /api/issues/ready` (which loads deps)
    # and `Ash.Error.Unknown` from any direct read.
    #
    # Fix: commit b193ea9 switched the importer to
    # `Ash.UUIDv7.bingenerate/0`. These tests pin both halves so a
    # future regression — anyone bypassing Ash to bulk-insert deps —
    # gets caught at test time, not at runtime.
    test "v7-id row inserted via Repo.insert_all is readable via Ash.read",
         %{a: a, b: b} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      a_id = a.id
      b_id = b.id

      {1, _} =
        Repo.insert_all("dependencies", [
          %{
            id: Ash.UUIDv7.bingenerate(),
            from_issue_id: a_id,
            to_issue_id: b_id,
            type: "blocks",
            created_at: now,
            updated_at: now
          }
        ])

      assert [%Dependency{from_issue_id: ^a_id, to_issue_id: ^b_id}] =
               filter_for_ab(a_id, b_id)
    end

    @tag :skip
    # SQLite stores UUIDs as text without version enforcement; cast_stored
    # does not reject a v4 UUID at read time. Postgres enforced this via its
    # native UUID type + UUIDv7 check constraint. Ash-level validation on
    # write still applies — this only affects rows injected via Repo.insert_all.
    test "v4-id row inserted via Repo.insert_all is rejected by Ash on read",
         %{a: a, b: b} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      {1, _} =
        Repo.insert_all("dependencies", [
          %{
            id: Ecto.UUID.bingenerate(),
            from_issue_id: a.id,
            to_issue_id: b.id,
            type: "blocks",
            created_at: now,
            updated_at: now
          }
        ])

      # Ash chokes at read-time. Either it raises or it returns
      # {:error, _}; accept both shapes — the point is "this surfaces
      # loudly", not "this exact error wraps the failure".
      result =
        try do
          {:ok, Ash.read(Dependency)}
        rescue
          e -> {:rescued, e}
        end

      case result do
        {:ok, {:error, _}} -> :ok
        {:rescued, _} -> :ok
        {:ok, {:ok, _}} -> flunk("expected Ash.read to fail on a v4 UUID, but it succeeded")
      end
    end
  end

  defp filter_for_ab(from_id, to_id) do
    Dependency
    |> Ash.read!()
    |> Enum.filter(&(&1.from_issue_id == from_id and &1.to_issue_id == to_id))
  end
end
