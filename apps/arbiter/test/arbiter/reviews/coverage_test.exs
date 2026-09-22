defmodule Arbiter.Reviews.CoverageTest do
  use Arbiter.DataCase, async: true

  require Ash.Query

  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.Coverage.Entry

  @head_sha "8e7a69ea" <> String.duplicate("0", 32)
  @other_sha "1234567890" <> String.duplicate("a", 30)

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "bd-6woz0x",
        mr_ref: "ryanrborn/arbiter#1631",
        head_sha: @head_sha,
        base_ref: "main",
        net_diff_id: "e3d29b52",
        kind: :reviewed,
        source: :review_gate
      },
      overrides
    )
  end

  describe "record/1 — kinds" do
    test "records a :reviewed entry" do
      assert {:ok, entry} = Coverage.record(base_attrs())

      assert entry.kind == :reviewed
      assert entry.source == :review_gate
      assert entry.head_sha == @head_sha
      assert entry.derived_from == nil
      assert %DateTime{} = entry.covered_at
    end

    test "records an :operator entry" do
      assert {:ok, entry} =
               Coverage.record(base_attrs(%{kind: :operator, source: :cli}))

      assert entry.kind == :operator
      assert entry.source == :cli
    end

    test "records a :mechanical entry with derived_from" do
      assert {:ok, parent} = Coverage.record(base_attrs())

      assert {:ok, entry} =
               Coverage.record(
                 base_attrs(%{
                   head_sha: @other_sha,
                   kind: :mechanical,
                   source: :watchdog,
                   derived_from: parent.id
                 })
               )

      assert entry.kind == :mechanical
      assert entry.derived_from == parent.id
    end

    test "rejects a :mechanical entry without derived_from" do
      assert {:error, %Ash.Error.Invalid{}} =
               Coverage.record(base_attrs(%{kind: :mechanical, source: :watchdog}))
    end

    test "rejects a non-:mechanical entry with derived_from set" do
      assert {:ok, parent} = Coverage.record(base_attrs())

      assert {:error, %Ash.Error.Invalid{}} =
               Coverage.record(base_attrs(%{head_sha: @other_sha, derived_from: parent.id}))
    end

    test "rejects a head_sha that isn't 40 hex characters" do
      assert {:error, %Ash.Error.Invalid{}} =
               Coverage.record(base_attrs(%{head_sha: "not-a-sha"}))
    end

    test "rejects a head_sha with uppercase hex" do
      assert {:error, %Ash.Error.Invalid{}} =
               Coverage.record(base_attrs(%{head_sha: String.upcase(@head_sha)}))
    end
  end

  describe "record/1 — idempotency" do
    test "a second identical call returns the existing row and doesn't insert" do
      assert {:ok, first} = Coverage.record(base_attrs())
      assert {:ok, second} = Coverage.record(base_attrs())

      assert first.id == second.id

      assert [%Entry{id: id}] =
               Entry
               |> Ash.Query.filter(mr_ref == ^first.mr_ref and head_sha == ^first.head_sha)
               |> Ash.read!()

      assert id == first.id
    end

    test "the same mr_ref/head_sha with a different kind is a distinct row" do
      assert {:ok, reviewed} = Coverage.record(base_attrs())

      assert {:ok, operator} =
               Coverage.record(base_attrs(%{kind: :operator, source: :cli}))

      refute reviewed.id == operator.id
    end

    test "the same mr_ref with a different head_sha is a distinct row" do
      assert {:ok, first} = Coverage.record(base_attrs())
      assert {:ok, second} = Coverage.record(base_attrs(%{head_sha: @other_sha}))

      refute first.id == second.id
    end
  end

  describe "append-only" do
    test "no update or destroy action exists on the entry resource" do
      action_types =
        Entry
        |> Ash.Resource.Info.actions()
        |> MapSet.new(& &1.type)

      refute MapSet.member?(action_types, :update)
      refute MapSet.member?(action_types, :destroy)
    end
  end

  # P7 (bd-60r6wp / #1738, §4.5).
  describe "mechanical_for_diff/5" do
    @diff """
    diff --git a/lib/a.ex b/lib/a.ex
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1,1 +1,2 @@
     x
    +y
    """

    @moved """
    diff --git a/lib/a.ex b/lib/a.ex
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -40,1 +40,2 @@
     x
    +y
    """

    test "derives a :mechanical row from the entry the head's diff fingerprints to" do
      fingerprint = Arbiter.Mergers.NetDiff.fingerprint(@diff)
      {:ok, parent} = Coverage.record(base_attrs(%{net_diff_id: fingerprint}))

      attrs = Coverage.mechanical_for_diff([parent], @other_sha, "main", @moved, :watchdog)

      assert %{kind: :mechanical, head_sha: @other_sha, derived_from: derived, source: :watchdog} =
               attrs

      assert derived == parent.id
      assert attrs.net_diff_id == fingerprint
      assert {:ok, %{kind: :mechanical}} = Coverage.record(attrs)
    end

    test "nil when the content differs, the head is already covered, or nothing fingerprints" do
      {:ok, parent} =
        Coverage.record(base_attrs(%{net_diff_id: Arbiter.Mergers.NetDiff.fingerprint(@diff)}))

      authored = @moved <> "+z\n"

      assert Coverage.mechanical_for_diff([parent], @other_sha, "main", authored) == nil
      assert Coverage.mechanical_for_diff([parent], @head_sha, "main", @moved) == nil
      assert Coverage.mechanical_for_diff([parent], @other_sha, "main", "") == nil
      assert Coverage.mechanical_for_diff([parent], @other_sha, nil, @moved) == nil
      assert Coverage.mechanical_for_diff([], @other_sha, "main", @moved) == nil
    end
  end

  describe "covered_heads/1" do
    test "newest first, deduplicated across kinds" do
      {:ok, older} = Coverage.record(base_attrs())

      {:ok, _} =
        Coverage.record(
          base_attrs(%{head_sha: @other_sha, kind: :mechanical, derived_from: older.id,
            covered_at: DateTime.add(older.covered_at, 60, :second)})
        )

      {:ok, _} = Coverage.record(base_attrs(%{kind: :operator, source: :cli}))

      assert Coverage.covered_heads("ryanrborn/arbiter#1631") == [@other_sha, @head_sha]
      assert Coverage.covered_heads("nobody#1") == []
      assert Coverage.covered_heads(nil) == []
    end
  end
end
