defmodule Arbiter.Polecat.PRTemplateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Beads.Issue
  alias Arbiter.Polecat.PRTemplate

  describe "read/1" do
    test "returns nil when .github/pull_request_template.md doesn't exist" do
      tmp = System.tmp_dir!() |> Path.join("gte020-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert PRTemplate.read(tmp) == nil
    end

    test "returns the file contents when present" do
      tmp = System.tmp_dir!() |> Path.join("gte020-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, ".github"))
      File.write!(Path.join(tmp, ".github/pull_request_template.md"), "## Summary\n\n- hi\n")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert PRTemplate.read(tmp) == "## Summary\n\n- hi\n"
    end
  end

  describe "fill/3 — basic substitutions" do
    test "substitutes known placeholders" do
      bead = %Issue{
        id: "gte-020",
        title: "PRTemplate module",
        description: "Tracker-agnostic template helper.",
        priority: 1,
        issue_type: :feature,
        tracker_type: :none,
        tracker_ref: nil
      }

      template = """
      ## Summary

      {{bead.title}} ({{bead.id}}, {{bead.priority}})

      {{bead.description}}
      """

      out = PRTemplate.fill(template, bead)
      assert out =~ "PRTemplate module (gte-020, P1)"
      assert out =~ "Tracker-agnostic template helper."
    end

    test "unknown placeholders are left verbatim" do
      bead = %Issue{id: "x-1", title: "t", priority: 2, issue_type: :task, tracker_type: :none}
      template = "{{bead.title}} / {{not.a.key}}"
      assert PRTemplate.fill(template, bead) == "t / {{not.a.key}}"
    end

    test "nil bead fields render as empty strings" do
      bead = %Issue{
        id: "x-1",
        title: "t",
        description: nil,
        acceptance: nil,
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      template = "[{{bead.description}}]"
      assert PRTemplate.fill(template, bead) == ""
      # ^^ the only placeholder is empty so the whole line drops
    end
  end

  describe "fill/3 — tracker integration" do
    test ":none tracker produces empty tracker.link and the line is dropped" do
      bead = %Issue{
        id: "gte-020",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      template = """
      ## Summary

      Tracker: {{tracker.link}}

      Body here.
      """

      out = PRTemplate.fill(template, bead)
      refute out =~ "Tracker:"
      refute out =~ "{{tracker.link}}"
      assert out =~ "Body here."
    end

    test ":none tracker leaves multi-placeholder lines partially blank, not dropped" do
      bead = %Issue{
        id: "gte-020",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      # tracker.link is empty, but bead.id is non-empty → line stays.
      template = "{{bead.id}} — {{tracker.link}}"
      out = PRTemplate.fill(template, bead)
      assert out == "gte-020 — "
    end

    test "tracker.ref renders empty for :none-tracked beads" do
      bead = %Issue{
        id: "gte-020",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      assert PRTemplate.fill("{{tracker.ref}}", bead) == ""
    end

    test "tracker.type renders the atom as string" do
      bead = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      assert PRTemplate.fill("type: {{tracker.type}}", bead) == "type: none"
    end

    test "unregistered tracker type (:linear / :github pre-Phase-5) — safe_link_for catches the raise" do
      # Trackers.link_for raises ArgumentError for unregistered tracker types.
      # PRTemplate should treat that as no-link and drop the line, not crash.
      # (:jira is registered as of gte-029; :linear and :github remain Phase 5.)
      bead = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :linear,
        tracker_ref: "LIN-1"
      }

      template = "Link: {{tracker.link}}"
      assert PRTemplate.fill(template, bead) == ""
    end
  end

  describe "fill/3 — line-granularity dropping" do
    test "trailing whitespace doesn't prevent line drop" do
      bead = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      # The line contains just the placeholder. It should drop entirely.
      template = "before\n{{tracker.link}}\nafter"
      assert PRTemplate.fill(template, bead) == "before\nafter"
    end

    test "headings without placeholders are preserved verbatim" do
      bead = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      template = "## Header\n\n{{tracker.link}}\n\n## Next"
      out = PRTemplate.fill(template, bead)
      assert out =~ "## Header"
      assert out =~ "## Next"
      refute out =~ "{{"
    end
  end
end
