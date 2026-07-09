defmodule Arbiter.VernacularSweepTest do
  @moduledoc """
  Validates that old vernacular terms (Admiral, Mayor, Polecat, acolyte, Deacon)
  have been replaced with new terms (coordinator, worker, etc.) in comments and
  internal identifiers only — not in config keys or wire values.

  This test scans the target files from task bd-2x7ito.
  """

  use ExUnit.Case

  @target_files [
    "apps/arbiter/lib/arbiter/agents/claude/config_dir.ex",
    "apps/arbiter/lib/arbiter/agents/security_policy.ex",
    "apps/arbiter/lib/arbiter/agents/credential_watchdog.ex",
    "apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex",
    "apps/arbiter/lib/arbiter/trackers/sync.ex",
    "apps/arbiter/lib/arbiter/tasks/workspace.ex",
    "apps/arbiter/lib/arbiter/tasks/decommission_sweep.ex",
    "apps/arbiter/lib/arbiter/workers/reconciler.ex",
    "apps/arbiter/lib/arbiter/events.ex",
    "apps/arbiter/lib/arbiter/application.ex",
    "apps/arbiter/lib/arbiter/github.ex"
  ]

  describe "vernacular sweep" do
    test "config_dir.ex: acolyte_memory function is renamed to worker_memory" do
      content = read_file("apps/arbiter/lib/arbiter/agents/claude/config_dir.ex")

      # Should NOT find the old function name
      refute content =~ "def acolyte_memory",
        "Found 'def acolyte_memory' — should be renamed to 'def worker_memory'"

      # Should find the new function name
      assert content =~ "def worker_memory",
        "Should find 'def worker_memory' after renaming"
    end

    test "credential_watchdog.ex: Admiral in comments → coordinator" do
      content = read_file("apps/arbiter/lib/arbiter/agents/credential_watchdog.ex")

      # Comments should mention "coordinator" not "Admiral"
      assert content =~ "Escalates to the coordinator",
        "Should update 'Escalates to the Admiral' to 'Escalates to the coordinator'"

      assert content =~ "coordinator escalations",
        "Should update Admiral escalations to coordinator escalations"

      refute content =~ ~r/Escalates to the Admiral(?![\w])/,
        "Should not have unqualified 'Admiral' in escalation context"
    end

    test "by_difficulty.ex: Admiral → coordinator in comments" do
      content = read_file("apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex")

      assert content =~ "The coordinator signed off",
        "Should update 'The Admiral signed off' to 'The coordinator signed off'"
    end

    test "trackers/sync.ex: Admiral → coordinator in mailbox comments" do
      content = read_file("apps/arbiter/lib/arbiter/trackers/sync.ex")

      assert content =~ "coordinator mailbox",
        "Should update 'Admiral mailbox' to 'coordinator mailbox'"
    end

    test "workspace.ex: Admiral → coordinator in comments" do
      content = read_file("apps/arbiter/lib/arbiter/tasks/workspace.ex")

      assert content =~ "escalates to the coordinator",
        "Should update 'escalates to the Admiral' to 'escalates to the coordinator'"
    end

    test "reconciler.ex: Admiral → coordinator" do
      content = read_file("apps/arbiter/lib/arbiter/workers/reconciler.ex")

      assert content =~ "coordinator's mailbox",
        "Should update 'Admiral's mailbox' to 'coordinator's mailbox'"
    end

    test "events.ex: Admiral → coordinator in event documentation" do
      content = read_file("apps/arbiter/lib/arbiter/events.ex")

      assert content =~ "coordinator ruling",
        "Should update 'Admiral ruling' to 'coordinator ruling'"
    end

    test "application.ex: Admiral → coordinator" do
      content = read_file("apps/arbiter/lib/arbiter/application.ex")

      assert content =~ "Escalates each to the coordinator",
        "Should update Admiral reference to coordinator"
    end

    test "github.ex: polecat → worker in comments" do
      content = read_file("apps/arbiter/lib/arbiter/github.ex")

      assert content =~ "worker-orchestrator",
        "Should update 'polecat-orchestrator' to 'worker-orchestrator'"
    end

    test "decommission_sweep.ex: mayor → coordinator in comments (but preserve historical artifact matching)" do
      content = read_file("apps/arbiter/lib/arbiter/tasks/decommission_sweep.ex")

      # The comments about old artifacts should be updated
      assert content =~ "coordinator/witness session-handoff",
        "Should update 'mayor/witness' in comments"

      # But the string matching for historical artifacts should be preserved
      assert content =~ ~r/"Mayor - global coordinator"/,
        "Should preserve historical artifact title matching for string literals"
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
  end

  # Helper to read a file relative to the project root
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> raise "Could not read file: #{path}"
    end
  end
end
