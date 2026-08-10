defmodule Arbiter.Loop.RepoDocPatchTest do
  @moduledoc """
  bd-1cusio: the pure merge logic behind the repo `CLAUDE.md` write path.

  `RepoDocPatch.upsert/4` computes the *new file content* for a repo's
  `CLAUDE.md` given the current content and one lesson to add or update. It
  never touches disk or git — `Arbiter.Loop` wires it to the filesystem.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Loop.RepoDocPatch

  describe "upsert/4 — no existing managed section" do
    test "creates the managed section when the file is empty" do
      assert {:ok, %{content: content, removed: []}} =
               RepoDocPatch.upsert("", "fp-1", "tests need FLAG=1 set")

      assert content =~ RepoDocPatch.begin_marker()
      assert content =~ RepoDocPatch.end_marker()
      assert content =~ "tests need FLAG=1 set"
    end

    test "appends the managed section after existing human content" do
      existing = "# My Repo\n\nSome human-written notes.\n"

      assert {:ok, %{content: content}} = RepoDocPatch.upsert(existing, "fp-1", "lesson one")

      assert String.starts_with?(content, existing)
      assert content =~ "lesson one"
    end
  end

  describe "upsert/4 — existing managed section" do
    test "appends a new entry without disturbing an existing one" do
      {:ok, %{content: first}} = RepoDocPatch.upsert("", "fp-1", "lesson one")
      assert {:ok, %{content: second}} = RepoDocPatch.upsert(first, "fp-2", "lesson two")

      assert second =~ "lesson one"
      assert second =~ "lesson two"
      # Exactly one begin/end pair — the section was rewritten, not duplicated.
      assert length(String.split(second, RepoDocPatch.begin_marker())) == 2
      assert length(String.split(second, RepoDocPatch.end_marker())) == 2
    end

    test "re-applying the same fingerprint updates the entry in place, not a duplicate" do
      {:ok, %{content: first}} = RepoDocPatch.upsert("", "fp-1", "old text")
      assert {:ok, %{content: second}} = RepoDocPatch.upsert(first, "fp-1", "new text")

      refute second =~ "old text"
      assert second =~ "new text"
      assert length(String.split(second, "fp-1")) == 2
    end

    test "content outside the managed markers survives an upsert" do
      existing = "# Human header\n\nHand-written rule: never rm -rf.\n"
      {:ok, %{content: with_section}} = RepoDocPatch.upsert(existing, "fp-1", "lesson one")

      assert {:ok, %{content: updated}} = RepoDocPatch.upsert(with_section, "fp-2", "lesson two")

      assert updated =~ "# Human header"
      assert updated =~ "Hand-written rule: never rm -rf."
    end

    test "a human edit inside the file but outside the markers is preserved across an upsert" do
      base = "# Human header\n\nHand rule.\n"
      {:ok, %{content: with_section}} = RepoDocPatch.upsert(base, "fp-1", "lesson one")

      # Simulate a human adding a new paragraph above the managed section.
      humanly_edited =
        String.replace(with_section, "# Human header\n", "# Human header\n\nAnother note.\n")

      assert {:ok, %{content: updated}} =
               RepoDocPatch.upsert(humanly_edited, "fp-2", "lesson two")

      assert updated =~ "Another note."
      assert updated =~ "lesson one"
      assert updated =~ "lesson two"
    end
  end

  describe "upsert/4 — size cap" do
    test "evicts the oldest entries once the section exceeds the cap, and names what it dropped" do
      {:ok, %{content: c1}} = RepoDocPatch.upsert("", "fp-1", String.duplicate("a", 40))
      {:ok, %{content: c2}} = RepoDocPatch.upsert(c1, "fp-2", String.duplicate("b", 40))

      assert {:ok, %{content: c3, removed: removed}} =
               RepoDocPatch.upsert(c2, "fp-3", String.duplicate("c", 40), cap_bytes: 100)

      assert removed != []
      assert "fp-1" in removed
      refute c3 =~ String.duplicate("a", 40)
      assert c3 =~ String.duplicate("c", 40)
    end

    test "a single entry that alone exceeds the cap is rejected, not silently truncated" do
      assert {:error, {:entry_too_large, _}} =
               RepoDocPatch.upsert("", "fp-1", String.duplicate("x", 500), cap_bytes: 100)
    end
  end

  describe "upsert/4 — invalid entry text" do
    test "rejects a multi-line lesson instead of silently dropping lines after the first" do
      assert {:error, :invalid_entry_text} =
               RepoDocPatch.upsert("", "fp-1", "first line\nsecond line")
    end

    test "rejects a lesson containing the begin marker" do
      assert {:error, :invalid_entry_text} =
               RepoDocPatch.upsert("", "fp-1", "text with #{RepoDocPatch.begin_marker()} inside")
    end

    test "rejects a lesson containing the end marker" do
      assert {:error, :invalid_entry_text} =
               RepoDocPatch.upsert("", "fp-1", "text with #{RepoDocPatch.end_marker()} inside")
    end
  end
end
