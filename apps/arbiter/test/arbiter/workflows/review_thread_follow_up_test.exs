defmodule Arbiter.Workflows.ReviewThreadFollowUpTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.ReviewThreadFollowUp

  describe "instructions/1" do
    test "always requires a per-thread reply naming the fix sha" do
      text = ReviewThreadFollowUp.instructions(%{})

      assert text =~ "reply"
      assert text =~ "Addressed in"
      assert text =~ "<sha>"
    end

    test "always includes the pushback/escalation guidance" do
      text = ReviewThreadFollowUp.instructions(%{})

      assert text =~ "do NOT implement it"
      assert text =~ "escalate"
    end

    test "default policy (unset map): resolve bot threads, leave human threads alone" do
      text = ReviewThreadFollowUp.instructions(%{})

      assert text =~ "Bot"
      assert text =~ "resolve"
      assert text =~ "Human"
      assert text =~ "do NOT resolve"
    end

    test "resolve_bot_threads: false tells the worker to leave bot threads unresolved" do
      text = ReviewThreadFollowUp.instructions(%{resolve_bot_threads: false})

      [_, bot_section] = String.split(text, "Bot / automated-reviewer threads", parts: 2)
      [bot_clause | _] = String.split(bot_section, "Human reviewer threads", parts: 2)

      assert bot_clause =~ "do NOT resolve"
    end

    test "resolve_human_threads: true tells the worker to resolve human threads" do
      text = ReviewThreadFollowUp.instructions(%{resolve_human_threads: true})

      [_, human_section] = String.split(text, "Human reviewer threads", parts: 2)
      [human_clause | _] = String.split(human_section, "Resolve via:", parts: 2)

      refute human_clause =~ "do NOT resolve"
      assert human_clause =~ "resolve"
    end
  end
end
