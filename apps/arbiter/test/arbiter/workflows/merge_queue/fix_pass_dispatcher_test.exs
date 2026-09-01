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
      assert prompt =~ "arb message coordinator"
      assert prompt =~ "arb done"
    end

    test "offers the CI-retry verb, with the granularity warning (bd-5mzzww / #1448)" do
      context = %{
        task: %Issue{id: "bd-fix2"},
        branch: "feature/bd-fix2",
        target_branch: "main",
        checks: [%{name: "playwright-smoke", summary: "review app 502", url: nil}]
      }

      prompt = FixPassDispatcher.prompt_for(context)

      # The incident: the only re-run a human reaches for reuses the stale
      # upstream deploy, so it is guaranteed to fail identically.
      assert prompt =~ "ci_rerun"
      assert prompt =~ "all_jobs"
      assert prompt =~ "workflow"
      assert prompt =~ "failed_jobs"
      assert prompt =~ ~r/reuse[sd]?/i
    end

    test "gives an 'infra, not my diff' verdict somewhere to go (bd-5mzzww / #1448)" do
      context = %{
        task: %Issue{id: "bd-fix3"},
        branch: "feature/bd-fix3",
        target_branch: "main",
        checks: []
      }

      prompt = FixPassDispatcher.prompt_for(context)

      # A follow-up worker reached exactly this conclusion hours before the
      # human did, and had nowhere to put it but free-text chat.
      assert prompt =~ "ci_mark_external"
      assert prompt =~ "evidence"
    end
  end

  describe "registry_suffix/0" do
    test "is the :fixpass suffix the Watchdog watches for" do
      assert FixPassDispatcher.registry_suffix() == ":fixpass"
    end
  end

  describe "dispatch/1 guards" do
    test "returns {:error, :missing_task_id} without a task id" do
      assert {:error, :missing_task_id} = FixPassDispatcher.dispatch(%{})
    end
  end
end
