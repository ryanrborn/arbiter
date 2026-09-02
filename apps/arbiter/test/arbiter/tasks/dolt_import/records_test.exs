defmodule Arbiter.Tasks.DoltImport.RecordsTest do
  @moduledoc """
  The importer writes `issues` and `dependencies` rows with `Repo.insert_all/3`,
  around Ash. On SQLite every id column is plain `:text`: the adapter stores
  the bytes it is handed and hands the same bytes back, and Ash's non-strict
  load keeps a value its type rejects rather than failing the read. A 16-byte
  binary id therefore "reads" but can never be fetched by id, and a 16-byte
  `workspace_id` never matches the hyphenated string Ash wrote for every
  other row. These tests pin the only shape that round-trips: the string.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Tasks.DoltImport.Mapper

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "dolt-ws", prefix: "dlt"})
    {:ok, ws: ws, now: DateTime.utc_now() |> DateTime.truncate(:microsecond)}
  end

  test "issue_record/3 rows bulk-inserted around Ash belong to the workspace Ash sees",
       %{ws: ws, now: now} do
    row = %{"id" => "dlt-a1b2c", "title" => "imported", "status" => "open"}

    {1, _} = Repo.insert_all("issues", [Mapper.issue_record(row, ws.id, now)])

    issue = Ash.get!(Issue, "dlt-a1b2c")
    assert issue.workspace_id == ws.id

    assert [%Issue{id: "dlt-a1b2c"}] =
             Issue
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.read!()
  end

  test "dependency_record/3 rows bulk-inserted around Ash are fetchable by id",
       %{ws: ws, now: now} do
    {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})
    row = %{"issue_id" => a.id, "depends_on_id" => b.id, "type" => "blocks"}

    rec = Mapper.dependency_record(row, :blocks, now)
    {1, _} = Repo.insert_all("dependencies", [rec])

    a_id = a.id
    b_id = b.id
    id = rec.id

    assert %Dependency{id: ^id, from_issue_id: ^a_id, to_issue_id: ^b_id} =
             Ash.get!(Dependency, id)
  end
end
