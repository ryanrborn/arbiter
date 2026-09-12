defmodule Arbiter.Mergers.NetDiffTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.NetDiff

  @reviewed """
  diff --git a/lib/foo.ex b/lib/foo.ex
  index 1111111..2222222 100644
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -10,6 +10,7 @@ defmodule Foo do
     def bar do
       :ok
     end
  +  def baz, do: :ok
   end
  """

  describe "fingerprint/1" do
    test "is stable across the line-number shift a merge from the base branch causes" do
      # A merge from main that touched an earlier part of the same file moves
      # every hunk down; the PR's own contribution is byte-identical.
      shifted = String.replace(@reviewed, "@@ -10,6 +10,7 @@", "@@ -42,6 +42,7 @@")

      assert NetDiff.fingerprint(shifted) == NetDiff.fingerprint(@reviewed)
    end

    test "is stable across blob-hash churn in the index line" do
      rehashed = String.replace(@reviewed, "index 1111111..2222222", "index 9999999..8888888")

      assert NetDiff.fingerprint(rehashed) == NetDiff.fingerprint(@reviewed)
    end

    test "changes when an added line changes" do
      # A conflict resolution that invents new content is NOT reviewed content.
      resolved = String.replace(@reviewed, "+  def baz, do: :ok", "+  def baz, do: :error")

      refute NetDiff.fingerprint(resolved) == NetDiff.fingerprint(@reviewed)
    end

    test "changes when a whole file is added" do
      extra = @reviewed <> "diff --git a/lib/new.ex b/lib/new.ex\n+defmodule New do\n+end\n"

      refute NetDiff.fingerprint(extra) == NetDiff.fingerprint(@reviewed)
    end

    test "changes when context around the addition changes" do
      # Fail-closed: we cannot tell a clean base merge that rewrote the context
      # from an authored edit, so a changed context line counts as unreviewed.
      recontexted = String.replace(@reviewed, "    :ok\n", "    :error\n")

      refute NetDiff.fingerprint(recontexted) == NetDiff.fingerprint(@reviewed)
    end

    test "returns nil for content it cannot fingerprint" do
      assert NetDiff.fingerprint(nil) == nil
      assert NetDiff.fingerprint("") == nil
      assert NetDiff.fingerprint("   \n\n") == nil
    end
  end

  describe "equivalent?/2" do
    test "two fingerprints of the same net diff are equivalent" do
      shifted = String.replace(@reviewed, "@@ -10,6 +10,7 @@", "@@ -42,6 +42,7 @@")

      assert NetDiff.equivalent?(@reviewed, shifted)
    end

    test "differing net diffs are not equivalent" do
      refute NetDiff.equivalent?(@reviewed, @reviewed <> "+trailing\n")
    end

    test "an unreadable diff is never equivalent" do
      refute NetDiff.equivalent?(@reviewed, nil)
      refute NetDiff.equivalent?(nil, nil)
      refute NetDiff.equivalent?("", "")
    end
  end
end
