defmodule Arbiter.Workflows.MergeQueue.FixPassDispatcherTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  describe "render_checks/1" do
    test "renders each failing check's name, url, and indented summary" do
      rendered =
        FixPassDispatcher.render_checks([
          %{
            name: "test (1.16)",
            summary: "lib/foo_test.exs:12\nassertion failed",
            url: "https://x/9"
          }
        ])

      assert rendered =~ "test (1.16)"
      assert rendered =~ "(https://x/9)"
      assert rendered =~ "lib/foo_test.exs:12"
      assert rendered =~ "assertion failed"
    end

    test "falls back to a clear hint when no checks were captured" do
      assert FixPassDispatcher.render_checks([]) =~ "No check details were captured"
    end

    test "omits the url parenthetical when there is no url" do
      rendered = FixPassDispatcher.render_checks([%{name: "build", summary: "boom", url: nil}])
      assert rendered =~ "build"
      refute rendered =~ "()"
    end
  end

  describe "prompt_for/1" do
    test "is narrowly scoped to fixing CI on the same branch and embeds the checks" do
      context = %{
        task: %Issue{id: "bd-fix1"},
        branch: "feature/bd-fix1",
        target_branch: "main",
        checks: [%{name: "test", summary: "1 failed", url: nil}]
      }

      prompt = FixPassDispatcher.prompt_for(context)

      assert prompt =~ "CI fix-pass worker for task bd-fix1"
      assert prompt =~ "feature/bd-fix1"
      assert prompt =~ "do NOT open a new PR"
      assert prompt =~ "Failing checks:"
      assert prompt =~ "test"
      assert prompt =~ "1 failed"
      assert prompt =~ "arb message admiral"
      assert prompt =~ "arb done"
    end
  end

  describe "registry_suffix/0" do
    test "is the :fixpass suffix the Warden watches for" do
      assert FixPassDispatcher.registry_suffix() == ":fixpass"
    end
  end

  describe "dispatch/1 guards" do
    test "returns {:error, :missing_task_id} without a task id" do
      assert {:error, :missing_task_id} = FixPassDispatcher.dispatch(%{})
    end
  end
end
