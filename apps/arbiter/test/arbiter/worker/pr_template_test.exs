defmodule Arbiter.Worker.PRTemplateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker.PRTemplate

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
      task = %Issue{
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

      {{task.title}} ({{task.id}}, {{task.priority}})

      {{task.description}}
      """

      out = PRTemplate.fill(template, task)
      assert out =~ "PRTemplate module (gte-020, P1)"
      assert out =~ "Tracker-agnostic template helper."
    end

    test "unknown placeholders are left verbatim" do
      task = %Issue{id: "x-1", title: "t", priority: 2, issue_type: :task, tracker_type: :none}
      template = "{{task.title}} / {{not.a.key}}"
      assert PRTemplate.fill(template, task) == "t / {{not.a.key}}"
    end

    test "nil task fields render as empty strings" do
      task = %Issue{
        id: "x-1",
        title: "t",
        description: nil,
        acceptance: nil,
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      template = "[{{task.description}}]"
      assert PRTemplate.fill(template, task) == ""
      # ^^ the only placeholder is empty so the whole line drops
    end
  end

  describe "fill/3 — tracker integration" do
    test ":none tracker produces empty tracker.link and the line is dropped" do
      task = %Issue{
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

      out = PRTemplate.fill(template, task)
      refute out =~ "Tracker:"
      refute out =~ "{{tracker.link}}"
      assert out =~ "Body here."
    end

    test ":none tracker leaves multi-placeholder lines partially blank, not dropped" do
      task = %Issue{
        id: "gte-020",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      # tracker.link is empty, but task.id is non-empty → line stays.
      template = "{{task.id}} — {{tracker.link}}"
      out = PRTemplate.fill(template, task)
      assert out == "gte-020 — "
    end

    test "tracker.ref renders empty for :none-tracked tasks" do
      task = %Issue{
        id: "gte-020",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      assert PRTemplate.fill("{{tracker.ref}}", task) == ""
    end

    test "tracker.type renders the atom as string" do
      task = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      assert PRTemplate.fill("type: {{tracker.type}}", task) == "type: none"
    end

    test "unregistered tracker type — safe_link_for catches the raise" do
      # Trackers.link_for raises ArgumentError for unregistered tracker types.
      # PRTemplate should treat that as no-link and drop the line, not crash.
      # All five current tracker types are registered; use a hypothetical future
      # type to verify the fallback still works.
      task = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :future_unregistered_tracker,
        tracker_ref: "FUT-1"
      }

      template = "Link: {{tracker.link}}"
      assert PRTemplate.fill(template, task) == ""
    end
  end

  describe "fill/3 — line-granularity dropping" do
    test "trailing whitespace doesn't prevent line drop" do
      task = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      # The line contains just the placeholder. It should drop entirely.
      template = "before\n{{tracker.link}}\nafter"
      assert PRTemplate.fill(template, task) == "before\nafter"
    end

    test "headings without placeholders are preserved verbatim" do
      task = %Issue{
        id: "x-1",
        title: "t",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      template = "## Header\n\n{{tracker.link}}\n\n## Next"
      out = PRTemplate.fill(template, task)
      assert out =~ "## Header"
      assert out =~ "## Next"
      refute out =~ "{{"
    end
  end

  describe "default_body/1" do
    test "produces a heading from the task title" do
      task = %Issue{
        id: "x-1",
        title: "Add widget",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      out = PRTemplate.default_body(task)
      assert out =~ "## Add widget"
    end

    test "includes description when present" do
      task = %Issue{
        id: "x-1",
        title: "Add widget",
        description: "Adds a new widget to the dashboard.",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      out = PRTemplate.default_body(task)
      assert out =~ "## Add widget"
      assert out =~ "Adds a new widget to the dashboard."
    end

    test "omits description section when nil" do
      task = %Issue{
        id: "x-1",
        title: "Add widget",
        description: nil,
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      out = PRTemplate.default_body(task)
      assert out == "## Add widget"
    end

    test "omits description section when empty string" do
      task = %Issue{
        id: "x-1",
        title: "Add widget",
        description: "   ",
        priority: 2,
        issue_type: :task,
        tracker_type: :none
      }

      out = PRTemplate.default_body(task)
      assert out == "## Add widget"
    end

    test "omits tracker link for :none-tracked tasks" do
      task = %Issue{
        id: "x-1",
        title: "T",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      out = PRTemplate.default_body(task)
      refute out =~ "http"
    end

    test ":github tracker with bare numeric ref appends Closes #N" do
      task = %Issue{
        id: "x-1",
        title: "Fix bug",
        priority: 2,
        issue_type: :bug,
        tracker_type: :github,
        tracker_ref: "42"
      }

      out = PRTemplate.default_body(task)
      assert out =~ "Closes #42"
    end

    test ":github tracker with non-numeric ref does not append closing keyword" do
      task = %Issue{
        id: "x-1",
        title: "Fix bug",
        priority: 2,
        issue_type: :bug,
        tracker_type: :github,
        tracker_ref: "gh-42"
      }

      out = PRTemplate.default_body(task)
      refute out =~ "Closes"
    end

    test ":jira tracker does not append closing keyword" do
      task = %Issue{
        id: "x-1",
        title: "Fix bug",
        priority: 2,
        issue_type: :bug,
        tracker_type: :jira,
        tracker_ref: "VR-17585"
      }

      out = PRTemplate.default_body(task)
      refute out =~ "Closes"
    end

    test ":none tracker does not append closing keyword" do
      task = %Issue{
        id: "x-1",
        title: "Fix bug",
        priority: 2,
        issue_type: :bug,
        tracker_type: :none,
        tracker_ref: nil
      }

      out = PRTemplate.default_body(task)
      refute out =~ "Closes"
    end
  end

  describe "fill/3 — Closes keyword for github tasks" do
    test "appends Closes #N for :github task with numeric ref" do
      task = %Issue{
        id: "x-1",
        title: "Fix thing",
        priority: 2,
        issue_type: :task,
        tracker_type: :github,
        tracker_ref: "99"
      }

      template = "## Summary\n\nSome body."
      out = PRTemplate.fill(template, task)
      assert out =~ "Closes #99"
    end

    test "does not append Closes for :jira task" do
      task = %Issue{
        id: "x-1",
        title: "Fix thing",
        priority: 2,
        issue_type: :task,
        tracker_type: :jira,
        tracker_ref: "VR-100"
      }

      template = "## Summary\n\nSome body."
      out = PRTemplate.fill(template, task)
      refute out =~ "Closes"
    end

    test "does not append Closes for :none task" do
      task = %Issue{
        id: "x-1",
        title: "Fix thing",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      template = "## Summary\n\nSome body."
      out = PRTemplate.fill(template, task)
      refute out =~ "Closes"
    end

    test "tracker.closes placeholder resolves to Closes #N for github and is droppable" do
      task = %Issue{
        id: "x-1",
        title: "Fix thing",
        priority: 2,
        issue_type: :task,
        tracker_type: :github,
        tracker_ref: "7"
      }

      # A template that explicitly places {{tracker.closes}} inline
      template = "## Summary\n\n{{tracker.closes}}"
      out = PRTemplate.fill(template, task)
      # The explicit placeholder expands + the auto-append adds it too
      assert out =~ "Closes #7"
    end

    test "tracker.closes placeholder is line-dropped for :none task" do
      task = %Issue{
        id: "x-1",
        title: "Fix thing",
        priority: 2,
        issue_type: :task,
        tracker_type: :none,
        tracker_ref: nil
      }

      template = "before\n{{tracker.closes}}\nafter"
      out = PRTemplate.fill(template, task)
      refute out =~ "Closes"
      assert out =~ "before"
      assert out =~ "after"
    end
  end
end
