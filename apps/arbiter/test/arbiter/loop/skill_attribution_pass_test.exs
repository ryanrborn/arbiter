defmodule Arbiter.Loop.SkillAttributionPassTest do
  @moduledoc """
  bd-5w8h0r acceptance, end to end over the real queue: every category the
  analyser can emit resolves to a target, the rows apply against real skills,
  and a second pass over the same window replaces its clause rather than
  appending a copy.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{FindingBuckets, PendingWrite, Proposals, Report, SkillClause}
  alias Arbiter.Tasks.Workspace

  @fleet_skills ~w(systematic-debugging test-driven-development verification-before-completion)

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "attribution-ws", prefix: "at"})

    for name <- @fleet_skills do
      {:ok, _} = Arbiter.Skills.create_skill(%{name: name, body: "# #{name}\n\nHand-written.\n"})
    end

    %{ws: ws}
  end

  # Enough evidence to clear the default fleet bar (>= 3 incidents, >= 2 tasks)
  # so every row lands :proposed and is actually applicable.
  defp report do
    struct(Report, %{
      window: %{label: "7d", since: ~U[2026-08-28 00:00:00Z], until: ~U[2026-09-04 00:00:00Z]},
      totals: %{},
      finding_categories:
        Enum.map(FindingBuckets.categories(), fn category ->
          %{
            category: category,
            incidents: 4,
            run_ids: ["run-a-#{category}", "run-b-#{category}", "run-c-#{category}"],
            tasks: ["bd-aaaaaa", "bd-bbbbbb"],
            example: "reviewer said: #{category} on the error branch"
          }
        end)
    })
  end

  defp pass(ws), do: Proposals.record_all(report(), workspace_id: ws.id)

  defp clauses(body, slug),
    do: length(String.split(body, SkillClause.begin_marker(slug))) - 1

  test "every emitted category lands a :proposed row that names a real target", %{ws: ws} do
    %{rows: rows, dropped: []} = pass(ws)

    assert length(rows) == 5

    for row <- rows do
      assert row.state == :proposed, "#{row.category} did not clear the bar"
      assert is_binary(row.target), "#{row.category} still carries target: nil"
      assert row.kind in [:skill_patch, :skill_create]
    end

    # No :skill_patch may name a skill that does not exist — that row would
    # fail with `no skill named …` forever.
    for row <- Enum.filter(rows, &(&1.kind == :skill_patch)) do
      assert {:ok, _} = Arbiter.Skills.get_skill(row.target)
    end

    # The unhomed pair route to :skill_create instead, carrying a stub body.
    creates = Enum.filter(rows, &(&1.kind == :skill_create))
    assert length(creates) == 2

    for row <- creates do
      assert row.payload["name"] == row.target
      assert row.payload["body"] =~ "# #{row.target}"
      assert row.payload["body"] =~ SkillClause.begin_marker(row.payload["clause_id"])
      assert row.evidence_count == 3
      assert row.distinct_tasks == 2
    end
  end

  test "a second pass over the same window reinforces in place — no duplicate rows", %{ws: ws} do
    %{rows: first} = pass(ws)
    %{rows: second} = pass(ws)

    assert length(Ash.read!(PendingWrite)) == 5
    assert Enum.map(first, & &1.id) |> Enum.sort() == Enum.map(second, & &1.id) |> Enum.sort()

    # The payload is re-rendered every window and must be byte-identical for an
    # unchanged window — otherwise every pass would dirty the row.
    for {a, b} <- Enum.zip(Enum.sort_by(first, & &1.id), Enum.sort_by(second, & &1.id)) do
      assert a.payload == b.payload
    end
  end

  test "the homed rows apply against the real skills, and two categories share one skill", %{
    ws: ws
  } do
    %{rows: rows} = pass(ws)

    for row <- Enum.filter(rows, &(&1.kind == :skill_patch)) do
      assert {:ok, applied} = Loop.apply_pending(row.id, actor: "operator")
      assert applied.state == :applied
    end

    {:ok, tdd} = Arbiter.Skills.get_skill("test-driven-development")
    assert tdd.body =~ "Hand-written.", "the human-authored body must survive the splice"
    assert clauses(tdd.body, "missing-test-coverage") == 1
    assert clauses(tdd.body, "regression-in-existing-behaviour") == 1

    {:ok, vbc} = Arbiter.Skills.get_skill("verification-before-completion")
    assert clauses(vbc.body, "plausible-code-green-tests-inert-at-runtime") == 1
    assert vbc.body =~ "reviewer said:"
  end

  test "the unhomed rows apply as loop-managed skills carrying their evidence", %{ws: ws} do
    %{rows: rows} = pass(ws)

    for row <- Enum.filter(rows, &(&1.kind == :skill_create)) do
      assert {:ok, _} = Loop.apply_pending(row.id, actor: "operator")

      {:ok, skill} = Arbiter.Skills.get_skill(row.target)
      assert skill.managed_by == :loop
      assert skill.body =~ "reviewer said:"
      assert clauses(skill.body, row.payload["clause_id"]) == 1
    end

    assert {:ok, _} = Arbiter.Skills.get_skill("credential-hygiene")
    assert {:ok, _} = Arbiter.Skills.get_skill("context-budget-discipline")
  end

  test "re-running the pass after an apply replaces the clause rather than appending", %{ws: ws} do
    %{rows: rows} = pass(ws)
    tdd_rows = Enum.filter(rows, &(&1.target == "test-driven-development"))
    assert length(tdd_rows) == 2

    for row <- tdd_rows, do: {:ok, _} = Loop.apply_pending(row.id, actor: "operator")

    # A later window over the same finding: the applied rows are out of the
    # matching pool, so fresh rows are inserted — and applying those must
    # rewrite the clauses that are already in the body.
    %{rows: again} = pass(ws)

    for row <- Enum.filter(again, &(&1.target == "test-driven-development")) do
      assert row.state == :proposed
      assert {:ok, _} = Loop.apply_pending(row.id, actor: "operator")
    end

    {:ok, tdd} = Arbiter.Skills.get_skill("test-driven-development")
    assert clauses(tdd.body, "missing-test-coverage") == 1
    assert clauses(tdd.body, "regression-in-existing-behaviour") == 1
    assert tdd.body =~ "Hand-written."
  end
end
