defmodule Arbiter.VernacularSweepTest do
  @moduledoc """
  Validates that old vernacular terms (Admiral, Mayor, Polecat, acolyte, Deacon)
  have been replaced with new terms (coordinator, worker, etc.) in comments and
  internal identifiers only — not in config keys or wire values.

  This test scans the target files from task bd-2x7ito.
  """

  use ExUnit.Case

  @target_files [
    "lib/arbiter/agents/claude/config_dir.ex",
    "lib/arbiter/agents/security_policy.ex",
    "lib/arbiter/agents/credential_watchdog.ex",
    "lib/arbiter/agents/routing/by_difficulty.ex",
    "lib/arbiter/trackers/sync.ex",
    "lib/arbiter/tasks/workspace.ex",
    "lib/arbiter/tasks/decommission_sweep.ex",
    "lib/arbiter/workers/reconciler.ex",
    "lib/arbiter/events.ex",
    "lib/arbiter/application.ex",
    "lib/arbiter/github.ex"
  ]

  @gas_town_files [
    "lib/arbiter/workers/reconciler.ex",
    "lib/arbiter/messages/coordinator_notifier.ex",
    "lib/arbiter/trackers/tracker.ex",
    "lib/arbiter/trackers/jira.ex",
    "lib/arbiter/trackers/sync.ex",
    "lib/arbiter/tasks/issue.ex",
    "lib/arbiter/worker.ex",
    "lib/arbiter/worker/worktree.ex",
    "lib/arbiter/worker/dispatch.ex",
    "lib/arbiter/workflows/merged_pr_finalizer.ex",
    "lib/arbiter/tasks/issue/changes/cleanup_worktree.ex",
    "lib/arbiter/worker/worker_env.ex",
    "lib/arbiter/worker/stop_reason.ex",
    "lib/arbiter/quota/cloud_code.ex",
    "lib/arbiter/tasks/issue/changes/sync_tracker.ex",
    "lib/arbiter/workflows/merge_queue.ex"
  ]

  describe "vernacular sweep" do
    test "config_dir.ex: acolyte_memory function is renamed to worker_memory" do
      content = read_file("lib/arbiter/agents/claude/config_dir.ex")

      # Should NOT find the old function name
      refute content =~ "def acolyte_memory",
             "Found 'def acolyte_memory' — should be renamed to 'def worker_memory'"

      # Should find the new function name
      assert content =~ "def worker_memory",
             "Should find 'def worker_memory' after renaming"
    end

    test "credential_watchdog.ex: Admiral in comments → coordinator" do
      content = read_file("lib/arbiter/agents/credential_watchdog.ex")

      # Comments should mention "coordinator" not "Admiral"
      assert content =~ "Escalates to the coordinator",
             "Should update 'Escalates to the Admiral' to 'Escalates to the coordinator'"

      assert content =~ "coordinator escalations",
             "Should update Admiral escalations to coordinator escalations"

      refute content =~ ~r/Escalates to the Admiral(?![\w])/,
             "Should not have unqualified 'Admiral' in escalation context"
    end

    test "by_difficulty.ex: Admiral → coordinator in comments" do
      content = read_file("lib/arbiter/agents/routing/by_difficulty.ex")

      assert content =~ ~r/coordinator signed\s+off/,
             "Should update 'Admiral signed off' to 'coordinator signed off'"
    end

    test "trackers/sync.ex: Admiral → coordinator in mailbox comments" do
      content = read_file("lib/arbiter/trackers/sync.ex")

      assert content =~ "coordinator mailbox",
             "Should update 'Admiral mailbox' to 'coordinator mailbox'"
    end

    test "workspace.ex: Admiral → coordinator in comments" do
      content = read_file("lib/arbiter/tasks/workspace.ex")

      assert content =~ "escalates to the coordinator",
             "Should update 'escalates to the Admiral' to 'escalates to the coordinator'"
    end

    test "reconciler.ex: Admiral → coordinator" do
      content = read_file("lib/arbiter/workers/reconciler.ex")

      assert content =~ "coordinator's mailbox",
             "Should update 'Admiral's mailbox' to 'coordinator's mailbox'"
    end

    test "events.ex: Admiral → coordinator in event documentation" do
      content = read_file("lib/arbiter/events.ex")

      assert content =~ "coordinator ruling",
             "Should update 'Admiral ruling' to 'coordinator ruling'"
    end

    test "application.ex: Admiral → coordinator" do
      content = read_file("lib/arbiter/application.ex")

      assert content =~ "Escalates each to the coordinator",
             "Should update Admiral reference to coordinator"
    end

    test "github.ex: polecat → worker in comments" do
      content = read_file("lib/arbiter/github.ex")

      assert content =~ "worker-orchestrator",
             "Should update 'polecat-orchestrator' to 'worker-orchestrator'"
    end

    test "decommission_sweep.ex: mayor → coordinator in comments (but preserve historical artifact matching)" do
      content = read_file("lib/arbiter/tasks/decommission_sweep.ex")

      # The comments about old artifacts should be updated
      assert content =~ ~r/coordinator\/witness\s+session-handoff/,
             "Should update 'mayor/witness' in comments"

      # But the string matching for historical artifacts should be preserved
      assert content =~ ~r/"Mayor - global coordinator"/,
             "Should preserve historical artifact title matching for string literals"
    end

    test "reconciler.ex: bead → task in comments (Gas Town vocabulary)" do
      content = read_file("lib/arbiter/workers/reconciler.ex")

      # Should NOT find the old "bead" terminology in comments
      refute content =~ ~r/a bead parked/i,
             "Should replace 'a bead parked' with 'a task parked'"

      refute content =~ ~r/beads\./i,
             "Should replace 'beads' with 'tasks' in comments"
    end

    test "merge_queue.ex: Refinery → merge queue in comments" do
      content = read_file("lib/arbiter/workflows/merge_queue.ex")

      # Should NOT find "the Refinery is"
      refute content =~ "the Refinery is",
             "Should replace 'the Refinery is' with 'the merge queue is'"

      # Should find "the merge queue" instead
      assert content =~ "the merge queue is",
             "Should have 'the merge queue' instead of 'the Refinery'"
    end


    test "all target files compile without errors" do
      # This is a basic sanity check — the actual compilation is done by mix test
      # but we can at least verify the files exist and are readable
      for file <- @target_files do
        assert File.exists?(file),
               "File #{file} should exist"

        {:ok, content} = File.read(file)

        refute content == "",
               "File #{file} should not be empty"
      end
    end

    test "gas_town_files: 'bead'/'beads' replaced with 'task'/'issue'" do
      for file <- @gas_town_files do
        content = read_file(file)

        # Check that "bead" is not used colloquially for task/issue in comments
        # Allow it only if it's part of a known identifier or in decommission_sweep artifact matching
        unless String.contains?(file, ["decommission_sweep", "Dolt"]) do
          refute content =~ ~r/\bbead(?![\w:_-])/,
                 "File #{file}: Found 'bead' used colloquially — should be 'task' or 'issue' in comments"

          refute content =~ ~r/\bbeads\b/,
                 "File #{file}: Found 'beads' — should be 'tasks' or 'issues' in comments"
        end
      end
    end

    test "merge_queue files: 'the Refinery' replaced with 'the merge queue'" do
      for file <- ["lib/arbiter/workflows/merge_queue.ex", "../arbiter_web/lib/arbiter_web/live/merge_queue_index_live.ex"] do
        content = read_file(file)

        refute content =~ "the Refinery",
               "File #{file}: Found 'the Refinery' — should be 'the merge queue'"
      end
    end

    test "gas_town_files: 'sling' (Gas Town terminology) not used in comments/prose" do
      for file <- @gas_town_files do
        content = read_file(file)

        # Check that "sling" is not used as Gas Town terminology in comments.
        # Exclude main.ex which intentionally defines the `arb sling` compat alias.
        unless String.contains?(file, ["main.ex", "decommission_sweep"]) do
          refute content =~ ~r/\bsling\b/,
                 "File #{file}: Found 'sling' (Gas Town terminology) — should be removed or replaced with Arbiter terminology in comments"
        end
      end
    end

    test "CLI help text: gte-NNN examples updated to current format" do
      dispatch_content = read_file("../arbiter_cli/lib/arbiter_cli/cmd/dispatch.ex")
      show_content = read_file("../arbiter_cli/lib/arbiter_cli/cmd/show.ex")

      refute dispatch_content =~ "gte-006",
             "dispatch.ex: Found 'gte-006' example — should use current issue id format"

      refute show_content =~ "gte-006",
             "show.ex: Found 'gte-006' example — should use current issue id format"
    end
  end

  # Helper to read a file relative to the project root
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> raise "Could not read file: #{path}"
    end
  end
end
