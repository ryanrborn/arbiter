defmodule Arbiter.Sessions.RefineDoctrineTest do
  @moduledoc """
  bd-980x89 — the filing doctrine as a versioned template, with a
  per-workspace override (task AC3, AC4).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.RefineDoctrine
  alias Arbiter.Tasks.Workspace

  describe "template/0 — the anchors later edits must not silently drop (AC4)" do
    test "states the session ends on promotion" do
      assert RefineDoctrine.template() =~
               ~r/session ends when the bound issue is promoted/i
    end

    test "states D5 is never assigned by this session" do
      assert RefineDoctrine.template() =~ ~r/D5 is never\s+assigned by this session/
    end

    test "states task type means no PR" do
      doc = RefineDoctrine.template()
      assert doc =~ "`task`"
      assert doc =~ ~r/no PR/
      assert doc =~ ~r/never use\s+.?task.?\s+for code work/i
    end

    test "states the POST-MERGE AC pattern with verify_after_deploy" do
      doc = RefineDoctrine.template()
      assert doc =~ "POST-MERGE"
      assert doc =~ "verify_after_deploy"
      assert doc =~ "[DEFERRED]"
    end

    test "states edges must be written before promoting" do
      assert RefineDoctrine.template() =~
               ~r/write all edges before promoting/i
    end
  end

  describe "content/1 — per-workspace override (AC3)" do
    test "no workspace → the built-in template" do
      assert RefineDoctrine.content(nil) == RefineDoctrine.template()
    end

    test "a workspace with no refine config → the built-in template" do
      ws = %Workspace{config: %{}}
      assert RefineDoctrine.content(ws) == RefineDoctrine.template()
    end

    test "config[\"refine\"][\"doctrine\"] replaces the template outright" do
      ws = %Workspace{config: %{"refine" => %{"doctrine" => "# Our own doctrine\n"}}}
      assert RefineDoctrine.content(ws) == "# Our own doctrine\n"
    end

    test "config[\"refine\"][\"doctrine_path\"] reads the file at render time" do
      path = Path.join(System.tmp_dir!(), "refine-doctrine-#{System.unique_integer([:positive])}.md")
      File.write!(path, "# Filed from disk\n")
      on_exit(fn -> File.rm(path) end)

      ws = %Workspace{config: %{"refine" => %{"doctrine_path" => path}}}
      assert RefineDoctrine.content(ws) == "# Filed from disk\n"
    end

    test "an unreadable doctrine_path falls back to the template rather than crashing" do
      ws = %Workspace{config: %{"refine" => %{"doctrine_path" => "/nonexistent/path.md"}}}
      assert RefineDoctrine.content(ws) == RefineDoctrine.template()
    end
  end
end
