defmodule Arbiter.Workflows.MergeQueue.ReviseDispatcherTest do
  @moduledoc """
  Pure unit tests for `render_feedback/1` — the review-thread follow-up
  protocol text (bd-76ydsu) it appends to the revise briefing, and the
  workspace resolve-policy flags it threads through.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.ReviseDispatcher

  describe "render_feedback/1" do
    test "still renders the existing feedback + same-branch instructions" do
      text =
        ReviseDispatcher.render_feedback(%{
          task_id: "bd-abc123",
          feedback: [%{kind: :review, state: "CHANGES_REQUESTED", body: "fix this"}]
        })

      assert text =~ "bd-abc123"
      assert text =~ "fix this"
      assert text =~ "do NOT open a new PR"
    end

    test "appends the review thread follow-up protocol" do
      text = ReviseDispatcher.render_feedback(%{task_id: "bd-abc123", feedback: []})

      assert text =~ "Review thread follow-up protocol"
      assert text =~ "Addressed in <sha>"
    end

    test "default policy (flags unset): resolve bot threads, leave human threads" do
      text = ReviseDispatcher.render_feedback(%{task_id: "bd-abc123", feedback: []})

      [_, bot_section] = String.split(text, "Bot / automated-reviewer threads", parts: 2)
      [bot_clause | _] = String.split(bot_section, "Human reviewer threads", parts: 2)
      assert bot_clause =~ "resolve it"
      refute bot_clause =~ "do NOT resolve"
    end

    test "resolve_bot_threads: false in args flows into the rendered policy" do
      text =
        ReviseDispatcher.render_feedback(%{
          task_id: "bd-abc123",
          feedback: [],
          resolve_bot_threads: false
        })

      [_, bot_section] = String.split(text, "Bot / automated-reviewer threads", parts: 2)
      [bot_clause | _] = String.split(bot_section, "Human reviewer threads", parts: 2)
      assert bot_clause =~ "do NOT resolve"
    end

    test "resolve_human_threads: true in args flows into the rendered policy" do
      text =
        ReviseDispatcher.render_feedback(%{
          task_id: "bd-abc123",
          feedback: [],
          resolve_human_threads: true
        })

      [_, human_section] = String.split(text, "Human reviewer threads", parts: 2)
      [human_clause | _] = String.split(human_section, "Resolve via:", parts: 2)
      refute human_clause =~ "do NOT resolve"
      assert human_clause =~ "resolve"
    end
  end
end
