defmodule Arbiter.Workflows.CodeReview.DiffScopeTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.CodeReview.DiffScope

  describe "build/1 + in_diff?/3" do
    test "added line is in diff" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      index 1111111..2222222 100644
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,3 +10,4 @@ defmodule Foo do
         def a do
      +    :new
         def b do
         end
      """

      scope = DiffScope.build(diff)

      assert DiffScope.in_diff?(scope, "lib/foo.ex", 11)
    end

    test "context line within a hunk is in diff" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,3 +10,4 @@ defmodule Foo do
         def a do
      +    :new
         def b do
         end
      """

      scope = DiffScope.build(diff)

      # "def b do" is a context line — new-file line 12
      assert DiffScope.in_diff?(scope, "lib/foo.ex", 12)
    end

    test "line outside any hunk is not in diff" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,3 +10,4 @@ defmodule Foo do
         def a do
      +    :new
         def b do
         end
      """

      scope = DiffScope.build(diff)

      refute DiffScope.in_diff?(scope, "lib/foo.ex", 500)
    end

    test "a file that isn't touched by the diff is never in scope" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,3 +10,4 @@ defmodule Foo do
         def a do
      +    :new
         def b do
         end
      """

      scope = DiffScope.build(diff)

      refute DiffScope.in_diff?(scope, "lib/bar.ex", 11)
    end

    test "removed-only line (deleted file) never resolves" do
      diff = """
      diff --git a/lib/gone.ex b/lib/gone.ex
      deleted file mode 100644
      --- a/lib/gone.ex
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -defmodule Gone do
      -end
      """

      scope = DiffScope.build(diff)

      refute DiffScope.in_diff?(scope, "lib/gone.ex", 1)
    end

    test "multiple hunks in the same file" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,2 +1,3 @@
       defmodule Foo do
      +  @moduledoc false
       end
      @@ -50,2 +51,3 @@ defmodule Foo do
         def z do
      +    :ok
         end
      """

      scope = DiffScope.build(diff)

      assert DiffScope.in_diff?(scope, "lib/foo.ex", 2)
      assert DiffScope.in_diff?(scope, "lib/foo.ex", 52)
      refute DiffScope.in_diff?(scope, "lib/foo.ex", 20)
    end

    test "multiple files in one diff" do
      diff = """
      diff --git a/a.ex b/a.ex
      --- a/a.ex
      +++ b/a.ex
      @@ -1,1 +1,2 @@
       existing
      +added
      diff --git a/b.ex b/b.ex
      --- a/b.ex
      +++ b/b.ex
      @@ -1,1 +1,2 @@
       existing
      +added
      """

      scope = DiffScope.build(diff)

      assert DiffScope.in_diff?(scope, "a.ex", 2)
      assert DiffScope.in_diff?(scope, "b.ex", 2)
    end

    test "empty diff has an empty scope" do
      scope = DiffScope.build("")

      refute DiffScope.in_diff?(scope, "any.ex", 1)
    end
  end
end
