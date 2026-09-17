defmodule Arbiter.Sessions.InstructionsTest do
  @moduledoc """
  bd-5v8f8l — the generated `CLAUDE.md` must carry the coordinator's *role*,
  not just its hazards.

  The reproduction (session 73754f39) violated no existing rule: it obeyed the
  live-checkout prohibition exactly and then implemented the fix itself in a
  legitimately-created worktree, because the prompt described worktree
  mechanics as its standing way of doing repository work and said nothing
  about filing. These assertions are the regression fence for both halves —
  the delegation rule and the research-delegation doctrine — under both
  `can_dispatch` values, since the default (`false`) is the arm where a naive
  "delegate via `worker_dispatch`" rule would render an instruction the
  session cannot execute.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Instructions
  alias Arbiter.Sessions.Session

  @checkout "/home/operator/dev/arbiter"

  defp session(overrides \\ []) do
    struct!(
      %Session{
        id: "sess1234",
        cwd: "/home/operator/.arbiter/sessions/sess1234/workspace",
        workspace_id: nil,
        can_dispatch: false
      },
      overrides
    )
  end

  defp render(opts \\ []) do
    Instructions.render(session(), Keyword.put_new(opts, :primary_checkout, @checkout))
  end

  describe "the delegation rule (AC1, AC3, AC4, AC6)" do
    for can_dispatch <- [true, false] do
      test "renders with can_dispatch: #{can_dispatch}" do
        doc = render(can_dispatch: unquote(can_dispatch))

        # The response to a bug is a filed issue, named by the tool that files it.
        assert doc =~ "task_create"
        assert doc =~ ~r/file.{0,40}not.{0,40}fix|not to fix it|don't fix it|do not fix it/i

        # Investigating is wanted; patching is not (AC4).
        assert doc =~ "file:line"
        assert doc =~ "acceptance criteria"

        # Coordinator-owned files stay the session's to write (AC6).
        assert doc =~ "memory/candidates"
      end
    end

    test "is placed early — ahead of the workspace and memory sections (AC1)" do
      doc = render()

      delegation = index_of(doc, "task_create")
      assert delegation < index_of(doc, "## Your workspace")
      assert delegation < index_of(doc, "## Memory")
    end

    test "terminates at 'file it and stop' when dispatch is disabled (AC3)" do
      doc = render(can_dispatch: false)

      # It must not hand the session a tool the very next paragraph disables.
      delegation = String.split(doc, "## Talking to Arbiter") |> hd()
      refute delegation =~ "worker_dispatch"

      assert doc =~ ~r/promot\w+ .{0,80}operator|operator.{0,80}promot/is
    end

    test "offers worker_dispatch only when dispatch is enabled" do
      assert render(can_dispatch: true) =~ "worker_dispatch"
    end
  end

  describe "the reframed checkout section (AC2, AC5, AC9)" do
    test "the nil arm does not present worktree creation as the default" do
      doc = Instructions.render(session(), primary_checkout: nil)

      refute doc =~ "the same discipline every dispatched worker follows"
      # Worktree mechanics are gated on an explicit operator ask.
      assert doc =~ ~r/worktree/
      assert doc =~ ~r/(when|if|only).{0,120}operator has asked you/is
    end

    test "the configured arm gates the worktree recipe behind the operator's ask" do
      doc = render()

      refute doc =~ "the same discipline every dispatched worker follows"
      assert doc =~ "git worktree add" or doc =~ "worktree add"
      assert doc =~ ~r/operator has asked you/i

      # AC9: the recipe and the non-live-clone idea are still discoverable.
      assert doc =~ "worktree add"
      assert doc =~ ~r/clone/i
    end

    test "keeps the live-checkout hazard text, including the mix/_build reason (AC5)" do
      doc = render()

      assert doc =~ @checkout
      assert doc =~ "hot-reload"
      assert doc =~ "Do **not** edit, create, or delete files under"
      assert doc =~ "mix"
      assert doc =~ "_build"
    end
  end

  describe "the research-delegation doctrine (AC10-AC14)" do
    for can_dispatch <- [true, false] do
      test "renders with can_dispatch: #{can_dispatch}" do
        doc = render(can_dispatch: unquote(can_dispatch))

        assert doc =~ ~r/research/i
        # The two-way split: fork/subagent vs a durable task-type issue.
        assert doc =~ ~r/subagent|fork/i
        assert doc =~ "task_update_progress"
        assert doc =~ "run_id"

        # The reason, which is what makes it stick (AC11).
        assert doc =~ ~r/context/i

        # Judgment stays (AC12).
        assert doc =~ ~r/messenger/i

        # Nothing compounds automatically (AC13).
        assert doc =~ ~r/nothing compounds/i
        assert doc =~ "CLAUDE.md"
      end
    end

    test "routes to the fork or to filing when dispatch is disabled (AC14)" do
      doc = render(can_dispatch: false)
      research = section(doc, "Research discipline")

      refute research =~ "worker_dispatch"
      assert research =~ ~r/operator/i
    end
  end

  describe "the event monitor section (bd-aqafdr)" do
    test "documents the Monitor tool, re-arming, since= reconnect, and the mailbox source of truth" do
      doc = render()
      monitor = section(doc, "Event monitor")

      assert monitor =~ "monitor.sh"
      assert monitor =~ "Monitor"
      assert monitor =~ ~r/background bash/i

      assert monitor =~ "coordinator_inbox"
      assert monitor =~ ~r/since=/

      # Every session gets every shared-mailbox event — the agent filters.
      assert monitor =~ ~r/every session/i
      assert monitor =~ ~r/ignore|filter|concern/i
    end
  end

  defp index_of(doc, needle) do
    case :binary.match(doc, needle) do
      {at, _} -> at
      :nomatch -> flunk("expected the rendered instructions to contain #{inspect(needle)}")
    end
  end

  defp section(doc, heading) do
    doc
    |> String.split(~r/^##\s+/m)
    |> Enum.find(&String.starts_with?(&1, heading))
    |> case do
      nil -> flunk("expected a `## #{heading}` section in the rendered instructions")
      body -> body
    end
  end
end
