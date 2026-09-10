defmodule Arbiter.Mergers.ReviewedShaTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.ReviewedSha

  describe "latch/3" do
    test "latches the head SHA the first time the MR is observed approved" do
      assert ReviewedSha.latch(nil, true, "sha-a") == "sha-a"
    end

    test "keeps the first latched SHA even as the head advances" do
      assert ReviewedSha.latch("sha-a", true, "sha-b") == "sha-a"
    end

    test "drops the latch when the MR is no longer approved" do
      # An approval dismissed by a push must not carry its baseline forward:
      # the next approval re-latches against whatever the reviewer saw.
      assert ReviewedSha.latch("sha-a", false, "sha-b") == nil
    end

    test "does not latch a missing or blank head SHA" do
      assert ReviewedSha.latch(nil, true, nil) == nil
      assert ReviewedSha.latch(nil, true, "") == nil
    end
  end

  describe "check/2" do
    test "no reviewed SHA → unguarded merge" do
      assert ReviewedSha.check(nil, "sha-b") == {:ok, nil}
    end

    test "head matches the reviewed SHA → merge guarded on that SHA" do
      assert ReviewedSha.check("sha-a", "sha-a") == {:ok, "sha-a"}
    end

    test "head unknown → still guarded on the reviewed SHA" do
      assert ReviewedSha.check("sha-a", nil) == {:ok, "sha-a"}
      assert ReviewedSha.check("sha-a", "") == {:ok, "sha-a"}
    end

    test "head advanced past the reviewed SHA → refuses" do
      assert ReviewedSha.check("sha-a", "sha-b") ==
               {:error, {:stale_reviewed_sha, "sha-a", "sha-b"}}
    end
  end
end
