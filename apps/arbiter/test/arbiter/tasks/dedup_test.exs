defmodule Arbiter.Tasks.DedupTest do
  @moduledoc """
  The duplicate-title pre-check, extracted from `ArbiterWeb.Api.IssueController`
  so the REST API and the dashboard's create form can't drift (bd-2cv4ws).

  The tracker leg needs a configured tracker and is covered end-to-end by the
  controller's 409 tests; these cover the local leg and the skip conditions.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "dd-#{System.unique_integer([:positive])}",
        prefix: "dd"
      })

    {:ok, ws: ws}
  end

  test "an open issue with the same title is a duplicate", %{ws: ws} do
    {:ok, existing} = Ash.create(Issue, %{title: "Fix the flaky test", workspace_id: ws.id})

    assert {:local_dup, [match]} = Dedup.check("Fix the flaky test", ws.id)
    assert match.id == existing.id
  end

  test "matching ignores case and surrounding whitespace", %{ws: ws} do
    {:ok, _} = Ash.create(Issue, %{title: "Fix the flaky test", workspace_id: ws.id})

    assert {:local_dup, [_]} = Dedup.check("  fix the FLAKY test  ", ws.id)
  end

  test "a closed issue with the same title is not a duplicate", %{ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "already handled", workspace_id: ws.id})
    {:ok, _} = Ash.update(task, %{}, action: :close)

    assert :ok = Dedup.check("already handled", ws.id)
  end

  test "an identical title in another workspace is not a duplicate", %{ws: ws} do
    {:ok, other} =
      Ash.create(Workspace, %{
        name: "dd-other-#{System.unique_integer([:positive])}",
        prefix: "do"
      })

    {:ok, _} = Ash.create(Issue, %{title: "shared title", workspace_id: other.id})

    assert :ok = Dedup.check("shared title", ws.id)
  end

  test "force skips the check entirely", %{ws: ws} do
    {:ok, _} = Ash.create(Issue, %{title: "dupe", workspace_id: ws.id})

    assert :ok = Dedup.check("dupe", ws.id, force: true)
  end

  test "a blank title or workspace is not checkable", %{ws: ws} do
    assert :ok = Dedup.check(nil, ws.id)
    assert :ok = Dedup.check("anything", nil)
  end

  test "message/1 names the colliding ids", %{ws: ws} do
    {:ok, existing} = Ash.create(Issue, %{title: "collide", workspace_id: ws.id})

    message = "collide" |> Dedup.check(ws.id) |> Dedup.message()

    assert message =~ "already exists"
    assert message =~ existing.id
  end
end
