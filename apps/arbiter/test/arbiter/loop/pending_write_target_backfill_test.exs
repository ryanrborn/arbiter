defmodule Arbiter.Loop.PendingWriteTargetBackfillTest do
  @moduledoc """
  bd-5w8h0r: the historical half of the attribution change.

  `target` is a fingerprint input, so giving a finding category a target
  changes the identity of every proposal in that category. The rows written
  before the attribution table existed carry `target: nil` and several windows
  of accumulated evidence; left alone they would sit live at a fingerprint no
  future pass can reach, while the pass opened a second, empty row beside
  them. This covers moving that evidence across.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{PendingWrite, PendingWriteTargetBackfill}

  require Ash.Query

  @homed "missing test coverage"
  @unhomed "secret / credential exposure"

  defp legacy_row!(attrs) do
    base = %{
      kind: :skill_patch,
      gist: "working-practice guardrail for: #{attrs[:category]}",
      scope: :fleet,
      state: :proposed,
      target: nil,
      incident_refs: ["run-a", "run-b", "run-c", "run-d"],
      task_refs: ["bd-one", "bd-two"],
      evidence_count: 4,
      distinct_tasks: 2,
      payload: %{
        "category" => attrs[:category],
        "example" => "no test for the error branch",
        "destination" => "skill"
      }
    }

    attrs = Map.merge(base, attrs)

    attrs =
      Map.put_new_lazy(attrs, :fingerprint, fn ->
        Loop.fingerprint(Map.merge(%{difficulty: nil, repo: nil}, attrs))
      end)

    {:ok, row} = Ash.create(PendingWrite, attrs, action: :propose)
    row
  end

  defp reload(row), do: Ash.get!(PendingWrite, row.id)

  defp successor(category) do
    fingerprint =
      Loop.fingerprint(%{
        kind: :skill_patch,
        target: "test-driven-development",
        category: category,
        difficulty: nil,
        repo: nil
      })

    PendingWrite
    |> Ash.Query.filter(fingerprint == ^fingerprint)
    |> Ash.read!()
  end

  test "supersedes a live target-less row and carries its evidence onto the successor" do
    row = legacy_row!(%{category: @homed})

    report = PendingWriteTargetBackfill.run()

    assert report.superseded == 1
    assert report.inserted == 1

    assert reload(row).state == :superseded

    assert [new] = successor(@homed)
    assert new.kind == :skill_patch
    assert new.target == "test-driven-development"
    assert new.category == @homed
    assert new.state == :proposed
    assert Enum.sort(new.incident_refs) == Enum.sort(row.incident_refs)
    assert Enum.sort(new.task_refs) == Enum.sort(row.task_refs)
    assert new.evidence_count == 4
    assert new.distinct_tasks == 2
    assert new.workspace_id == row.workspace_id
  end

  test "the successor carries a real clause payload, not the old evidence-only one" do
    legacy_row!(%{category: @homed})

    PendingWriteTargetBackfill.run()

    assert [new] = successor(@homed)
    assert new.payload["skill"] == "test-driven-development"
    assert new.payload["clause_id"] == "missing-test-coverage"
    assert new.payload["clause"] =~ "<!-- arbiter:loop:begin missing-test-coverage -->"
    assert new.payload["clause"] =~ "no test for the error branch"
    assert new.gist == "patch skill `test-driven-development`: #{@homed}"
    assert new.context_cost_tokens > 0
  end

  test "an unhomed category is re-homed as a :skill_create row" do
    legacy_row!(%{category: @unhomed})

    report = PendingWriteTargetBackfill.run()
    assert report.inserted == 1

    [new] =
      PendingWrite
      |> Ash.Query.filter(category == ^@unhomed and state != :superseded)
      |> Ash.read!()

    assert new.kind == :skill_create
    assert new.target == "credential-hygiene"
    assert new.payload["name"] == "credential-hygiene"
    assert new.payload["body"] =~ "credential-hygiene"
  end

  test "a category with no attribution row is left alone and counted unresolved" do
    row = legacy_row!(%{category: "some category nobody buckets"})

    report = PendingWriteTargetBackfill.run()

    assert report.unresolved == 1
    assert report.superseded == 0
    assert reload(row).state == :proposed
  end

  test "a rejected target-less row is left alone — the rejection is the record" do
    row = legacy_row!(%{category: @homed, state: :rejected})

    report = PendingWriteTargetBackfill.run()

    assert report.examined == 0
    assert reload(row).state == :rejected
    assert successor(@homed) == []
  end

  test "merges evidence onto an existing live successor rather than opening a duplicate" do
    old = legacy_row!(%{category: @homed, incident_refs: ["old-1"], task_refs: ["bd-old"]})

    new =
      legacy_row!(%{
        category: @homed,
        kind: :skill_patch,
        target: "test-driven-development",
        incident_refs: ["new-1"],
        task_refs: ["bd-new"],
        evidence_count: 1,
        distinct_tasks: 1,
        fingerprint:
          Loop.fingerprint(%{
            kind: :skill_patch,
            target: "test-driven-development",
            category: @homed,
            difficulty: nil,
            repo: nil
          })
      })

    report = PendingWriteTargetBackfill.run()

    assert report.merged == 1
    assert report.inserted == 0
    assert reload(old).state == :superseded

    merged = reload(new)
    assert Enum.sort(merged.incident_refs) == ["new-1", "old-1"]
    assert Enum.sort(merged.task_refs) == ["bd-new", "bd-old"]
    assert merged.evidence_count == 2
    assert merged.distinct_tasks == 2
  end

  test "is idempotent — a second run has nothing left to do" do
    legacy_row!(%{category: @homed})

    assert PendingWriteTargetBackfill.run().superseded == 1
    second = PendingWriteTargetBackfill.run()

    assert second.examined == 0
    assert second.superseded == 0
    assert second.inserted == 0
  end

  test "the successor applies cleanly against the real queue" do
    legacy_row!(%{category: @homed})
    {:ok, _} = Arbiter.Skills.create_skill(%{name: "test-driven-development", body: "# tdd\n"})

    PendingWriteTargetBackfill.run()
    [new] = successor(@homed)

    assert {:ok, applied} = Loop.apply_pending(new.id, actor: "operator")
    assert applied.state == :applied

    {:ok, skill} = Arbiter.Skills.get_skill("test-driven-development")
    assert skill.body =~ "<!-- arbiter:loop:begin missing-test-coverage -->"
    assert skill.body =~ "# tdd"
  end
end
