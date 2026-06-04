defmodule ArbiterCli.OutputTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Output

  describe "format_issue_line/1" do
    test "formats id, status, priority, title" do
      issue = %{"id" => "gte-006", "status" => "open", "priority" => 2, "title" => "CLI escript"}
      line = Output.format_issue_line(issue)
      assert line =~ "gte-006"
      assert line =~ "[open]"
      assert line =~ "P2"
      assert line =~ "CLI escript"
    end

    test "handles missing fields gracefully" do
      assert Output.format_issue_line(%{}) =~ "?"
    end
  end

  describe "format_issue_detail/1" do
    test "includes header and description sections" do
      issue = %{
        "id" => "gte-006",
        "title" => "CLI",
        "status" => "open",
        "priority" => 1,
        "issue_type" => "feature",
        "description" => "Build the thing"
      }

      out = Output.format_issue_detail(issue)
      assert out =~ "ID:"
      assert out =~ "gte-006"
      assert out =~ "Title:"
      assert out =~ "Description:"
      assert out =~ "Build the thing"
    end

    test "skips empty sections" do
      issue = %{"id" => "x", "title" => "T", "status" => "open"}
      out = Output.format_issue_detail(issue)
      refute out =~ "Description:"
      refute out =~ "Notes:"
    end

    test "renders tracker label only when tracker is meaningful" do
      issue = %{"id" => "x", "title" => "T", "tracker_type" => "jira", "tracker_ref" => "VR-1"}
      assert Output.format_issue_detail(issue) =~ "Tracker:"
      assert Output.format_issue_detail(issue) =~ "jira:VR-1"
    end

    test "skips tracker line when type is none or nil" do
      assert Output.format_issue_detail(%{"id" => "x", "title" => "T", "tracker_type" => "none"})
             |> String.contains?("Tracker:") == false
    end

    test "renders Difficulty as D<n> when set" do
      issue = %{"id" => "x", "title" => "T", "status" => "open", "difficulty" => 3}
      out = Output.format_issue_detail(issue)
      assert out =~ "Difficulty:"
      assert out =~ "D3"
    end

    test "omits Difficulty line when unset" do
      issue = %{"id" => "x", "title" => "T", "status" => "open"}
      refute Output.format_issue_detail(issue) =~ "Difficulty:"

      issue_nil = Map.put(issue, "difficulty", nil)
      refute Output.format_issue_detail(issue_nil) =~ "Difficulty:"
    end
  end

  describe "mode/1" do
    test "returns :json when --json present" do
      assert Output.mode(["foo", "--json", "bar"]) == :json
    end

    test "defaults to :text otherwise" do
      assert Output.mode(["foo", "bar"]) == :text
    end
  end

  describe "drop_json/1" do
    test "removes --json flag" do
      assert Output.drop_json(["a", "--json", "b"]) == ["a", "b"]
    end

    test "leaves args untouched when no --json" do
      assert Output.drop_json(["a", "b"]) == ["a", "b"]
    end
  end
end
