defmodule Arbiter.Worker.PhaseTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Phase

  defp author(status, attrs \\ %{}) do
    Map.merge(
      %{task_id: "bd-1", registry_key: "bd-1", status: status, role: nil, meta: %{}},
      attrs
    )
  end

  defp reviewer(attrs) do
    Map.merge(
      %{
        task_id: "bd-1#review",
        registry_key: "bd-1#review",
        status: :running,
        role: :reviewer,
        meta: %{role: :reviewer, reviews: "bd-1"}
      },
      attrs
    )
  end

  defp implementer(attrs) do
    Map.merge(
      %{
        task_id: "bd-1#review#impl1",
        registry_key: "bd-1#review#impl1",
        status: :running,
        role: :implementer,
        meta: %{role: :implementer, revises: "bd-1"}
      },
      attrs
    )
  end

  defp fix_pass(attrs) do
    Map.merge(
      %{
        task_id: "bd-1",
        registry_key: "bd-1:fixpass",
        status: :running,
        role: :fix_pass,
        meta: %{role: :fix_pass}
      },
      attrs
    )
  end

  defp conflict(attrs) do
    Map.merge(
      %{
        task_id: "bd-1",
        registry_key: "bd-1:conflict",
        status: :running,
        role: :conflict_resolver,
        meta: %{role: :conflict_resolver}
      },
      attrs
    )
  end

  describe "of/2 — the author's own agent" do
    test "a live main agent is :implementing" do
      assert Phase.of(author(:running, %{agent_live: true})) == :implementing
      assert Phase.of(author(:idle, %{agent_live: true})) == :implementing
      assert Phase.of(author(:resuming, %{agent_live: true})) == :implementing
    end

    test "a running record whose agent has exited is not :implementing" do
      refute Phase.of(author(:running, %{agent_live: false})) == :implementing
    end
  end

  describe "of/2 — what is live for this task" do
    test "a live reviewer reads as :in_review" do
      author = author(:awaiting_review_gate, %{agent_live: false})
      assert Phase.of(author, [reviewer(%{agent_live: true})]) == :in_review
    end

    test "a live implementer round reads as :addressing_review" do
      author = author(:awaiting_review_gate, %{agent_live: false})
      assert Phase.of(author, [implementer(%{agent_live: true})]) == :addressing_review
    end

    test "a live CI fix pass reads as :fixing_ci" do
      author = author(:awaiting_review, %{agent_live: false})
      assert Phase.of(author, [fix_pass(%{agent_live: true})]) == :fixing_ci
    end

    test "a live conflict resolver reads as :resolving_conflict" do
      author = author(:awaiting_review, %{agent_live: false})
      assert Phase.of(author, [conflict(%{agent_live: true})]) == :resolving_conflict
    end

    test "a subordinate whose own agent has exited does not claim the author's phase" do
      author = author(:awaiting_review, %{agent_live: false})
      assert Phase.of(author, [fix_pass(%{agent_live: false})]) == :waiting_ci_merge
    end

    test "siblings for other tasks are ignored" do
      author = author(:awaiting_review, %{agent_live: false})
      other = reviewer(%{agent_live: true, meta: %{role: :reviewer, reviews: "bd-999"}})
      assert Phase.of(author, [other]) == :waiting_ci_merge
    end
  end

  describe "of/2 — no agent anywhere" do
    test "an open MR with nothing running is :waiting_ci_merge" do
      assert Phase.of(author(:awaiting_review, %{agent_live: false})) == :waiting_ci_merge
    end

    test "a question or a parked failure is :waiting_on_you" do
      assert Phase.of(author(:awaiting, %{agent_live: false})) == :waiting_on_you
      assert Phase.of(author(:failed, %{agent_live: false})) == :waiting_on_you
    end

    test "the review gate spun up but nothing is live yet is :in_review" do
      assert Phase.of(author(:awaiting_review_gate, %{agent_live: false})) == :in_review
    end

    test "a live-status record between agents is :handing_off" do
      assert Phase.of(author(:running, %{agent_live: false})) == :handing_off
      assert Phase.of(author(:idle, %{agent_live: false})) == :handing_off
    end

    test "a completed worker is :done" do
      assert Phase.of(author(:completed, %{agent_live: false})) == :done
    end
  end

  describe "of/2 — subordinate rows report their own round" do
    test "each role names its own phase while its agent is live" do
      assert Phase.of(reviewer(%{agent_live: true})) == :in_review
      assert Phase.of(implementer(%{agent_live: true})) == :addressing_review
      assert Phase.of(fix_pass(%{agent_live: true})) == :fixing_ci
      assert Phase.of(conflict(%{agent_live: true})) == :resolving_conflict
    end

    test "a subordinate with no live agent is in transition, not in its round" do
      assert Phase.of(fix_pass(%{agent_live: false})) == :handing_off
    end
  end

  describe "of/2 — unknown liveness" do
    test "a snapshot that cannot answer keeps the old reading rather than inventing one" do
      # No :agent_live key at all — the pre-bd-aw2cyt behaviour, where a
      # :running record meant a running agent.
      assert Phase.of(author(:running)) == :implementing
      assert Phase.of(author(:awaiting_review)) == :waiting_ci_merge
    end
  end

  describe "annotate/1" do
    test "stamps :phase on every row using its siblings" do
      rows = [
        author(:awaiting_review_gate, %{agent_live: false}),
        reviewer(%{agent_live: true})
      ]

      assert [%{phase: :in_review}, %{phase: :in_review}] = Phase.annotate(rows)
    end

    test "leaves rows for unrelated tasks alone" do
      rows = [
        author(:running, %{agent_live: true}),
        %{
          task_id: "bd-2",
          registry_key: "bd-2",
          status: :awaiting,
          role: nil,
          meta: %{},
          agent_live: false
        }
      ]

      assert [%{phase: :implementing}, %{phase: :waiting_on_you}] = Phase.annotate(rows)
    end
  end

  describe "label/1" do
    test "every phase has a human label" do
      for phase <- Phase.phases() do
        assert is_binary(Phase.label(phase))
        assert Phase.label(phase) != ""
      end
    end
  end

  describe "any_agent_live?/2" do
    test "true when this task has an agent burning quota in any role" do
      assert Phase.any_agent_live?(author(:running, %{agent_live: true}), [])

      assert Phase.any_agent_live?(author(:awaiting_review_gate, %{agent_live: false}), [
               reviewer(%{agent_live: true})
             ])
    end

    test "false when the record is alive but nothing is running for it" do
      # The exact case bd-aw2cyt is about: a card that reads as work in
      # progress while no process exists.
      refute Phase.any_agent_live?(author(:awaiting_review_gate, %{agent_live: false}), [
               reviewer(%{agent_live: false})
             ])

      refute Phase.any_agent_live?(author(:awaiting, %{agent_live: false}), [])
    end

    test "unknown liveness is not a claim either way, and does not read as dead" do
      assert Phase.any_agent_live?(author(:running), [])
    end
  end

  # bd-92mx1m: a worker failed only so an automatic round can replace it (the
  # ReviewGate fix round, the Watchdog's awaiting_review auto-resume) has not
  # been parked for a person, so its task keeps its slot through the hand-off.
  describe "a :failed worker mid slot hand-off" do
    test "is handing off, not waiting on you" do
      assert Phase.of(author(:failed, %{meta: %{slot_handoff: true}})) == :handing_off
    end

    test "a plain :failed worker still waits on you" do
      assert Phase.of(author(:failed, %{meta: %{slot_handoff: false}})) == :waiting_on_you
      assert Phase.of(author(:failed)) == :waiting_on_you
    end

    test "an :awaiting worker is unaffected by the marker" do
      assert Phase.of(author(:awaiting, %{meta: %{slot_handoff: true}})) == :waiting_on_you
    end
  end
end
