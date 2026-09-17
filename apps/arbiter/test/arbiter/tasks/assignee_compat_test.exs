defmodule Arbiter.Tasks.AssigneeCompatTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.AssigneeCompat

  test "warns when params carry a string-keyed assignee" do
    assert AssigneeCompat.warnings(%{"assignee" => "alice", "title" => "x"}) == [
             AssigneeCompat.warning()
           ]
  end

  test "warns when params carry an atom-keyed assignee" do
    assert AssigneeCompat.warnings(%{assignee: "alice"}) == [AssigneeCompat.warning()]
  end

  test "no warning when assignee is absent" do
    assert AssigneeCompat.warnings(%{"title" => "x"}) == []
  end

  test "no warning for non-map input" do
    assert AssigneeCompat.warnings(nil) == []
  end
end
