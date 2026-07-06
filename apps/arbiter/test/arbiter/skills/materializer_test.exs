defmodule Arbiter.Skills.MaterializerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Skills.Materializer
  alias Arbiter.Skills.Skill

  setup do
    tmp = Path.join(System.tmp_dir!(), "mat-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp resolved(name, body, activation \\ :situational, metadata \\ %{}) do
    %{
      skill: %Skill{name: name, body: body, activation_mode: activation, metadata: metadata},
      activation: activation
    }
  end

  describe "materialize/2" do
    test "writes only the resolved set to .claude/skills/<name>/SKILL.md", %{tmp: tmp} do
      set = [resolved("tdd", "# TDD body"), resolved("debug", "# Debug body")]

      assert {:ok, written} = Materializer.materialize(tmp, set)
      assert Enum.sort(written) == ["debug", "tdd"]

      assert File.read!(Path.join(tmp, ".claude/skills/tdd/SKILL.md")) == "# TDD body"
      assert File.read!(Path.join(tmp, ".claude/skills/debug/SKILL.md")) == "# Debug body"

      # Nothing else leaked in.
      assert Path.wildcard(Path.join(tmp, ".claude/skills/*")) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
               ["debug", "tdd"]
    end

    test "adds the skills tree to the worktree git exclude", %{tmp: tmp} do
      {_, 0} = System.cmd("git", ["init", "-q", tmp])

      assert {:ok, _} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")])

      exclude = File.read!(Path.join(tmp, ".git/info/exclude"))
      assert exclude =~ ".claude/skills/"
    end

    test "nil worktree is a no-op" do
      assert Materializer.materialize(nil, [resolved("tdd", "# TDD")]) == {:ok, []}
    end

    test "empty set is a no-op", %{tmp: tmp} do
      assert Materializer.materialize(tmp, []) == {:ok, []}
      refute File.exists?(Path.join(tmp, ".claude"))
    end
  end

  describe "prompt_section/1" do
    test "empty set → empty string" do
      assert Materializer.prompt_section([]) == ""
    end

    test "always-on skills get an imperative /name directive" do
      section = Materializer.prompt_section([resolved("tdd", "# TDD", :always_on)])

      assert section =~ "Required skills"
      assert section =~ "MUST"
      assert section =~ "/tdd"
    end

    test "situational skills are advertised, not forced" do
      section = Materializer.prompt_section([resolved("debug", "# Debug", :situational)])

      assert section =~ "Available skills"
      assert section =~ "/debug"
      refute section =~ "MUST"
    end

    test "mixed set lists both blocks with descriptions from metadata" do
      set = [
        resolved("tdd", "# TDD", :always_on, %{"description" => "test first"}),
        resolved("debug", "# Debug", :situational)
      ]

      section = Materializer.prompt_section(set)
      assert section =~ "Required skills"
      assert section =~ "Available skills"
      assert section =~ "`/tdd` — test first"
      assert section =~ "/debug"
    end
  end
end
