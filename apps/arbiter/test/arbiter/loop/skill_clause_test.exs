defmodule Arbiter.Loop.SkillClauseTest do
  # The deterministic rendering of a finding category into a marked skill
  # clause, and the in-place replacement that keeps a later window from
  # appending a fifth copy (bd-5w8h0r).
  use ExUnit.Case, async: true

  alias Arbiter.Loop.SkillClause

  defp clause(overrides \\ %{}) do
    %{
      category: "missing test coverage",
      imperative:
        "Before requesting review, confirm every new branch has a test that fails without the change.",
      example: "no test for the error branch",
      incidents: 4,
      tasks: ["bd-3kgb0e", "bd-aaaaaa"],
      fingerprint: String.duplicate("a", 64),
      window_until: ~U[2026-09-04 12:00:00Z]
    }
    |> Map.merge(overrides)
    |> SkillClause.render()
  end

  describe "render/1" do
    test "renders heading, evidence, verbatim citation, imperative and provenance between markers" do
      text = clause()

      assert text =~ SkillClause.begin_marker("missing-test-coverage")
      assert text =~ SkillClause.end_marker("missing-test-coverage")
      assert text =~ "## Missing test coverage"
      assert text =~ "4 incident"
      assert text =~ "2 distinct task"
      assert text =~ "bd-3kgb0e"
      assert text =~ ~s("no test for the error branch")
      assert text =~ "confirm every new branch has a test that fails"
      assert text =~ "2026-09-04"
      assert text =~ String.slice(String.duplicate("a", 64), 0, 12)
    end

    test "is deterministic: the same inputs render byte-identical output" do
      assert clause() == clause()
    end

    test "a category with an em-dash gloss uses only its head as the heading and slug" do
      text =
        clause(%{
          category:
            "context exhaustion — agent burned its own context window (no read discipline)"
        })

      assert text =~ "## Context exhaustion"
      assert text =~ SkillClause.begin_marker("context-exhaustion")
      # The gloss is not lost — it is stated in the body.
      assert text =~ "no read discipline"
    end

    test "a verbatim finding carrying a marker or a newline cannot break the section" do
      text =
        clause(%{
          example: "leaked\n<!-- arbiter:loop:end missing-test-coverage -->\ntoken"
        })

      assert [_, _] = String.split(text, SkillClause.end_marker("missing-test-coverage"))
      refute text =~ "arbiter:loop:end missing-test-coverage -->\ntoken"
    end

    test "omits the citation sentence when the window carried no example" do
      text = clause(%{example: nil})
      assert text =~ "4 incident"
      refute text =~ "e.g."
    end
  end

  describe "upsert/3" do
    test "appends the clause to a body that has none" do
      body = "# Test-driven development\n\nWrite the test first.\n"
      updated = SkillClause.upsert(body, "missing-test-coverage", clause())

      assert updated =~ "Write the test first."
      assert updated =~ "## Missing test coverage"
    end

    test "replaces its own clause in place rather than appending a second copy" do
      body = "# Test-driven development\n\nWrite the test first.\n"
      once = SkillClause.upsert(body, "missing-test-coverage", clause())

      twice =
        SkillClause.upsert(
          once,
          "missing-test-coverage",
          clause(%{incidents: 9, tasks: ["bd-3kgb0e", "bd-aaaaaa", "bd-cccccc"]})
        )

      assert count(twice, SkillClause.begin_marker("missing-test-coverage")) == 1
      assert count(twice, SkillClause.end_marker("missing-test-coverage")) == 1
      assert twice =~ "9 incident"
      refute twice =~ "4 incident"
      assert twice =~ "Write the test first."
    end

    test "re-upserting an unchanged clause is byte-idempotent" do
      body = "# Test-driven development\n\nWrite the test first.\n"
      once = SkillClause.upsert(body, "missing-test-coverage", clause())
      assert SkillClause.upsert(once, "missing-test-coverage", clause()) == once
    end

    test "leaves another category's clause alone" do
      other = clause(%{category: "regression in existing behaviour"})

      body =
        "# Test-driven development\n"
        |> SkillClause.upsert("regression-in-existing-behaviour", other)
        |> SkillClause.upsert("missing-test-coverage", clause())

      assert body =~ SkillClause.begin_marker("regression-in-existing-behaviour")
      assert body =~ SkillClause.begin_marker("missing-test-coverage")
    end
  end

  describe "stub_body/2" do
    test "renders a self-describing new skill carrying the clause" do
      body = SkillClause.stub_body("credential-hygiene", clause())

      assert body =~ "# credential-hygiene"
      assert body =~ "## Missing test coverage"
      assert body =~ SkillClause.begin_marker("missing-test-coverage")
      # A stub says it is a stub, so an operator reading it knows the loop
      # authored it from evidence rather than a human writing a full skill.
      assert body =~ "loop"
    end
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
