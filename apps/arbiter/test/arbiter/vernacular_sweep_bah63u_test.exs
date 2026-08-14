defmodule Arbiter.VernacularSweepBah63uTest do
  @moduledoc """
  Validates that old vernacular terms (Admiral, acolyte, Warden, summons,
  Warships) reintroduced since the 2026-07-10 sweep (#859) have been
  replaced with new terms (coordinator, worker, Watchdog, escalates,
  Workspaces) in comments and prose. Task bd-bah63u.
  """

  use ExUnit.Case

  @target_files ~w(
    lib/arbiter/mcp/catalog.ex
    lib/arbiter/mcp/tools.ex
    lib/arbiter/worker/watchdog.ex
    lib/arbiter/worker/dispatch.ex
    lib/arbiter/worker/run_provenance.ex
    lib/arbiter/worker/worktree.ex
    lib/arbiter/worker/review_gate.ex
    lib/arbiter/worker/resume_context.ex
    lib/arbiter/worker/stop_reason.ex
    lib/arbiter/usage/workspace_backfill.ex
    lib/arbiter/messages/coordinator_notifier.ex
    lib/arbiter/mergers/github.ex
    lib/arbiter/mergers/gitlab.ex
    lib/arbiter/worker.ex
    lib/arbiter/workflows/merge_queue/conflict_resolver.ex
    lib/arbiter/workflows/merge_queue/fix_pass_dispatcher.ex
    lib/arbiter/workflows/conductor.ex
    lib/arbiter/workflows/work.ex
    lib/arbiter/workflows/merge_queue.ex
    lib/arbiter/workflows/pr_patrol.ex
    lib/arbiter/workflows/code_review/checks.ex
  )

  @web_target_files ~w(
    lib/arbiter_web/live/dashboard_live.ex
  )

  @cli_target_files ~w(
    lib/arbiter_cli/cmd/queue.ex
    lib/arbiter_cli/cmd/update.ex
  )

  describe "stale vocabulary is gone from lib targets" do
    for file <- @target_files do
      test "#{file}: no bare Admiral/acolyte/Warden/summons vocabulary remains" do
        content = read_file(unquote(file))

        refute content =~ ~r/\bAdmiral\b/,
               "#{unquote(file)} still contains 'Admiral' — should be 'coordinator'"

        refute content =~ ~r/\bacolyte(s)?\b/i,
               "#{unquote(file)} still contains 'acolyte' — should be 'worker'"

        refute content =~ ~r/\bWarden\b/,
               "#{unquote(file)} still contains 'Warden' — should be 'Watchdog'"

        refute content =~ ~r/\bsummons\b/i,
               "#{unquote(file)} still contains 'summons' — should be 'escalates'"
      end
    end
  end

  describe "stale vocabulary is gone from web targets" do
    for file <- @web_target_files do
      test "#{file}: no stale Warships label remains" do
        content = read_file(Path.join("../arbiter_web", unquote(file)))

        refute content =~ "Warships",
               "#{unquote(file)} still contains 'Warships'"
      end
    end
  end

  describe "stale vocabulary is gone from arbiter_cli targets" do
    for file <- @cli_target_files do
      test "#{file}: no bare Admiral vocabulary remains" do
        content = read_file(Path.join("../arbiter_cli", unquote(file)))

        refute content =~ ~r/\bAdmiral\b/,
               "#{unquote(file)} still contains 'Admiral' — should be 'coordinator'"
      end
    end
  end

  describe "workflows/work.ex mailbox grammar" do
    test "says 'a worker checks its mailbox', not 'an worker'" do
      content = read_file("lib/arbiter/workflows/work.ex")

      refute content =~ "an worker checks its mailbox",
             "should be 'a worker checks its mailbox', not 'an worker'"

      assert content =~ "a worker checks its mailbox",
             "expected 'a worker checks its mailbox' after the grammar fix"
    end
  end

  describe "MCP tool-description strings (highest priority)" do
    test "catalog.ex: coordinator_inbox description uses coordinator, not Admiral" do
      content = read_file("lib/arbiter/mcp/catalog.ex")

      assert content =~ "Read the coordinator escalation mailbox for the workspace",
             "catalog.ex coordinator_inbox description should read 'coordinator escalation mailbox'"

      assert content =~ "conductor failure escalation in the coordinator inbox",
             "catalog.ex resume_paused_branch description should say 'coordinator inbox'"
    end

    test "tools.ex: coordinator_inbox doc uses coordinator, not Admiral" do
      content = read_file("lib/arbiter/mcp/tools.ex")

      assert content =~ "The coordinator escalation mailbox for the bound workspace",
             "tools.ex @doc for coordinator_inbox should say 'coordinator escalation mailbox'"
    end
  end

  describe "watchdog.ex acolyte/Admiral/summons cluster" do
    test "renamed to worker/coordinator/escalates" do
      content = read_file("lib/arbiter/worker/watchdog.ex")

      assert content =~ "dispatch a fix-pass worker"
      assert content =~ "escalates to a human reviewer"
      assert content =~ "escalate to the coordinator on the first poll"
      assert content =~ "escalating to coordinator, staying parked"
    end
  end

  describe "coordinator_notifier.ex Warden→Watchdog" do
    test "message bodies say Watchdog, not Warden" do
      content = read_file("lib/arbiter/messages/coordinator_notifier.ex")

      assert content =~ "The Watchdog detected this on its merge poll"
      assert content =~ "The Watchdog auto-resolved this block"
    end
  end

  describe "mergers summons→escalates" do
    test "github.ex" do
      content = read_file("lib/arbiter/mergers/github.ex")
      assert content =~ "escalates to a human once"
    end

    test "gitlab.ex" do
      content = read_file("lib/arbiter/mergers/gitlab.ex")
      assert content =~ "escalates to a human once"
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> raise "Could not read file #{path}: #{inspect(reason)}"
    end
  end
end
