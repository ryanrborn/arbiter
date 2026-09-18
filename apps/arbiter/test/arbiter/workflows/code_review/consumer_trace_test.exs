defmodule Arbiter.Workflows.CodeReview.ConsumerTraceTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.CodeReview.ConsumerTrace

  @diff """
  diff --git a/lib/apex/token.ex b/lib/apex/token.ex
  index 1111111..2222222 100644
  --- a/lib/apex/token.ex
  +++ b/lib/apex/token.ex
  @@ -1,5 +1,5 @@
   defmodule Apex.Token do
  -  def sign(payload, algorithm) do
  +  def sign(payload) do
       :ok
     end
   end
  """

  describe "trace/2" do
    test "finds a consumer of a changed function signature in another file" do
      repo = fixture_repo(consumer?: true)

      assert [%{identifier: "sign", file: file, line: line, snippet: snippet}] =
               ConsumerTrace.trace(@diff, repo)

      assert file == "lib/apex/session.ex"
      assert line > 0
      assert snippet =~ "sign"
    end

    test "excludes matches inside the changed file itself" do
      repo = fixture_repo(consumer?: false)

      assert ConsumerTrace.trace(@diff, repo) == []
    end
  end

  defp fixture_repo(opts) do
    dir = Path.join(System.tmp_dir!(), "consumer-trace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib/apex"))

    File.write!(Path.join(dir, "lib/apex/token.ex"), """
    defmodule Apex.Token do
      def sign(payload) do
        :ok
      end
    end
    """)

    if Keyword.fetch!(opts, :consumer?) do
      File.write!(Path.join(dir, "lib/apex/session.ex"), """
      defmodule Apex.Session do
        def start(payload) do
          Apex.Token.sign(payload)
        end
      end
      """)
    end

    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", dir, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "-m", "init"])

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
