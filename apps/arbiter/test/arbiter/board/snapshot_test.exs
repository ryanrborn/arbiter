defmodule Arbiter.Board.SnapshotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-08-22 12:00:00Z]
  @yesterday ~U[2026-08-21 23:00:00Z]

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        status: :open,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        # bd-b5wyjd: the fixture is a *refined* issue, because that is what
        # every column but Backlog is about. Backlog tests pass `refined: false`
        # explicitly, which is also what a freshly created issue actually is.
        refined: true,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      attrs
    )
  end

  defp worker(task_id, status, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: task_id,
        status: status,
        workspace_id: "ws-1",
        current_step: :implement,
        started_at: @now,
        step_started_at: @now,
        mr_ref: nil,
        merger_url: nil,
        meta: %{}
      },
      attrs
    )
  end

  defp derive(overrides) do
    Snapshot.derive(
      Map.merge(
        %{
          issues: [],
          workers: [],
          blocked_by: %{},
          changed_files: %{},
          now: @now,
          slots_total: 4,
          quota: :ok,
          paused: false
        },
        Map.new(overrides)
      )
    )
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  defp parent_of(parent_id, child_id), do: {parent_id, child_id}

  describe "ready column" do
    test "holds open issues that have no live worker, highest priority first" do
      board =
        derive(
          issues: [
            issue("bd-a", %{priority: 3}),
            issue("bd-b", %{priority: 1}),
            issue("bd-c", %{priority: 1, created_at: @yesterday})
          ]
        )

      assert ids(board.ready) == ["bd-c", "bd-b", "bd-a"]
    end

    test "an open issue with a live worker belongs to Running, not Ready" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          workers: [worker("bd-a", :running)]
        )

      assert ids(board.ready) == ["bd-b"]
      assert ids(board.running) == ["bd-a"]
    end

    test "epics are not dispatchable work and never queue" do
      board = derive(issues: [issue("bd-a", %{issue_type: :epic}), issue("bd-b")])

      assert ids(board.ready) == ["bd-b"]
    end

    test "each card carries the scheduler's state and one-line reason" do
      board = derive(issues: [issue("bd-a"), issue("bd-b")])

      assert [
               %{id: "bd-a", state: :next, reason: "next up — dispatching..."},
               %{id: "bd-b", state: :queued, reason: "1 ahead in queue"}
             ] = board.ready
    end

    test "an open gating dependency surfaces as the card's reason" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-z"}, _] =
               board.ready

      assert board.promote == "bd-b"
    end

    test "file overlap with an in-flight worker holds the card" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-b")
          ],
          workers: [worker("bd-run", :running)],
          changed_files: %{"bd-run" => ["lib/board.ex"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: reason}, _] = board.ready
      assert reason == "blocked — lib/board.ex in flight on bd-run"
    end

    test "a running worker's own issue text counts as in-flight scope" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-run", %{status: :in_progress, description: "Touches `lib/board.ex` too."})
          ],
          workers: [worker("bd-run", :running)]
        )

      assert [
               %{
                 id: "bd-a",
                 state: :blocked,
                 reason: "blocked — lib/board.ex in flight on bd-run"
               }
             ] =
               board.ready
    end
  end

  # bd-b5wyjd — Backlog is Ready minus the refinement flag. Same filter, same
  # card, different order: newest-first, because an unrefined pile is a
  # to-think-about list, not a queue.
  describe "backlog column" do
    test "an unrefined open issue sits in Backlog, not Ready" do
      board = derive(issues: [issue("bd-a", %{refined: false}), issue("bd-b")])

      assert ids(board.backlog) == ["bd-a"]
      assert ids(board.ready) == ["bd-b"]
    end

    test "an issue with no refined flag at all reads as unrefined" do
      board = derive(issues: [Map.delete(issue("bd-a"), :refined)])

      assert ids(board.backlog) == ["bd-a"]
      assert ids(board.ready) == []
    end

    test "Backlog is newest-first — provisional, not a priority queue" do
      board =
        derive(
          issues: [
            issue("bd-old", %{refined: false, priority: 1, created_at: @yesterday}),
            issue("bd-new", %{refined: false, priority: 3, created_at: @now})
          ]
        )

      assert ids(board.backlog) == ["bd-new", "bd-old"]
    end

    test "an unrefined issue with a live worker belongs to Running, not Backlog" do
      board =
        derive(
          issues: [issue("bd-a", %{refined: false})],
          workers: [worker("bd-a", :running)]
        )

      assert ids(board.backlog) == []
      assert ids(board.running) == ["bd-a"]
    end

    test "a closed issue is not in Backlog, whatever its flag says" do
      board =
        derive(
          issues: [issue("bd-a", %{refined: false, status: :closed, updated_at: @now})],
          now: @now
        )

      assert ids(board.backlog) == []
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "epics are a rollup, so they never queue in Backlog either" do
      board =
        derive(issues: [issue("bd-a", %{refined: false, issue_type: :epic})])

      assert ids(board.backlog) == []
    end

    test "a refined but dependency-blocked card stays in Ready with its reason" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert ids(board.backlog) == []

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-z"}, _] =
               board.ready
    end

    test "an unrefined card is never the scheduler's promote, however free the slots" do
      board = derive(issues: [issue("bd-a", %{refined: false})], slots_total: 8)

      assert board.promote == nil
    end

    test "cards carry what a Backlog card is read by" do
      board =
        derive(
          issues: [
            issue("bd-a", %{refined: false, title: "think about caching"})
          ]
        )

      assert [
               %{
                 id: "bd-a",
                 title: "think about caching",
                 priority: 2,
                 difficulty: 2,
                 issue_type: :task,
                 workspace_id: "ws-1",
                 created_at: @now
               }
             ] = board.backlog
    end

    test "cards carry no assignee (bd-1ozks5: local assignee field removed)" do
      board =
        derive(
          issues: [issue("bd-a")],
          workers: [worker("bd-b", :running)]
        )

      assert [ready] = board.ready
      refute Map.has_key?(ready.card, :assignee)
      assert [running] = board.running
      refute Map.has_key?(running, :assignee)
    end
  end

  describe "manual ready order" do
    test "ids named in :ready_order lead the queue, in that order" do
      board =
        derive(
          issues: [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 2}), issue("bd-c")],
          ready_order: ["bd-c", "bd-b"]
        )

      assert ids(board.ready) == ["bd-c", "bd-b", "bd-a"]
    end

    test "an id the operator ranked but that is no longer Ready is simply ignored" do
      board = derive(issues: [issue("bd-a")], ready_order: ["bd-gone", "bd-a"])

      assert ids(board.ready) == ["bd-a"]
    end

    test "unranked cards keep priority order behind the ranked ones" do
      board =
        derive(
          issues: [
            issue("bd-a", %{priority: 3}),
            issue("bd-b", %{priority: 1}),
            issue("bd-c", %{priority: 2})
          ],
          ready_order: ["bd-a"]
        )

      assert ids(board.ready) == ["bd-a", "bd-b", "bd-c"]
    end

    test "the hand-ranked leader is the card the scheduler promotes" do
      board =
        derive(
          issues: [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 3})],
          ready_order: ["bd-b"]
        )

      assert board.promote == "bd-b"
    end
  end

  describe "empty/1" do
    test "is a full board shape a screen can render, reporting itself paused" do
      board = Arbiter.Board.Snapshot.empty(@now)

      assert board.backlog == []
      assert board.ready == []
      assert board.running == []
      assert board.waiting == []
      assert board.closed_today == []
      assert board.promote == nil
      assert board.slots_total == 0
      assert board.slots_free == 0
      assert board.quota == :ok
      # Paused, because nothing should claim a queue position in a queue this
      # process could not read.
      assert board.paused
      assert board.now == @now
    end
  end

  describe "slots" do
    test "every worker holding a subprocess consumes a slot" do
      board =
        derive(
          slots_total: 3,
          workers: [worker("bd-1", :running), worker("bd-2", :awaiting_review_gate)]
        )

      assert board.slots_total == 3
      assert board.slots_free == 1
    end

    test "a worker parked on its merge request still holds its task's slot" do
      # bd-45pwo1: an open MR is not a merge — the task's slot stays held
      # until it actually merges, closes, fails, or parks for a human.
      board = derive(slots_total: 2, workers: [worker("bd-1", :awaiting_review)])

      assert board.slots_free == 1
    end

    test "a merged (:completed) worker frees its task's slot" do
      board = derive(slots_total: 2, workers: [worker("bd-1", :completed)])

      assert board.slots_free == 2
    end

    test "no free slot holds the queue and says so" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-a")],
          workers: [worker("bd-1", :running)]
        )

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — no free worker slot"}] = board.ready
    end
  end

  describe "running column" do
    test "shows what the worker is doing right now" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [
            worker("bd-a", :running, %{
              current_step: :implement,
              meta: %{activity: "edit · scheduler.ex"}
            })
          ]
        )

      assert [
               %{
                 id: "bd-a",
                 title: "Task bd-a",
                 step: :implement,
                 activity: "edit · scheduler.ex"
               }
             ] =
               board.running
    end

    test "a worker under review is still running, not waiting on you" do
      board = derive(workers: [worker("bd-a", :awaiting_review_gate)])

      assert [%{id: "bd-a", activity: "in review"}] = board.running
      assert board.waiting == []
    end

    test "reviewer workers fold into the author's card instead of queueing twice" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review_gate),
            worker("bd-a#review", :running, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert ids(board.running) == ["bd-a"]
    end

    test "a ReviewGate fix-up round folds into the original issue's card, not a second one" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [
            worker("bd-a", :awaiting_review_gate),
            worker(review_id <> "#impl2", :running, %{
              meta: %{role: :implementer, revises: "bd-a"}
            })
          ]
        )

      assert [%{id: "bd-a", title: "Task bd-a", activity: "round 2 implementation"}] =
               board.running
    end

    test "a round-2+ reviewer pass shows a round-aware label on the author's card" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review_gate),
            worker(review_id <> "#r2", :running, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.running
    end

    test "a re-prompted round-2 reviewer pass still resolves the round label through the chain" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review_gate),
            worker(review_id <> "#r2#v2", :running, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.running
    end

    test "an author-only card's provider is the author's own" do
      board = derive(workers: [worker("bd-a", :running, %{meta: %{provider: "codex"}})])

      assert [%{id: "bd-a", provider: "codex"}] = board.running
    end

    test "an author awaiting review shows the gate worker's provider, not its own" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review_gate, %{meta: %{provider: "claude"}}),
            worker("bd-a#review", :running, %{
              meta: %{role: :reviewer, reviews: "bd-a", provider: "gemini"}
            })
          ]
        )

      assert [%{id: "bd-a", provider: "gemini"}] = board.running
    end

    test "an unknown provider is nil, not a guess" do
      board = derive(workers: [worker("bd-a", :running, %{meta: %{}})])

      assert [%{id: "bd-a", provider: nil}] = board.running
    end
  end

  describe "waiting column" do
    test "unions the parked and the merge-parked, longest wait first" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              step_started_at: ~U[2026-08-22 11:00:00Z],
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            }),
            worker("bd-b", :awaiting, %{
              step_started_at: @now,
              meta: %{await_reason: "needs a decision"}
            }),
            worker("bd-c", :awaiting_review, %{mr_ref: "!41", step_started_at: @yesterday}),
            worker("bd-d", :running)
          ]
        )

      assert ids(board.waiting) == ["bd-c", "bd-a", "bd-b"]
      refute Map.has_key?(board, :needs_you)
      refute Map.has_key?(board, :merge_queue)
    end

    test "carries the halt reason of a parked worker and the merge fields of a merge-parked one" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting, %{meta: %{await_reason: "needs a decision"}}),
            worker("bd-b", :awaiting_review, %{
              step_started_at: @yesterday,
              mr_ref: "!42",
              merger_url: "https://example.test/42",
              meta: %{last_merger_status: %{approved: false}}
            })
          ]
        )

      assert [
               %{id: "bd-b", mr_ref: "!42", merger_url: "https://example.test/42"},
               %{id: "bd-a", reason: "needs a decision"}
             ] = board.waiting

      assert [%{merger_status: %{approved: false}}, %{merger_status: nil}] = board.waiting
    end

    # bd-2mv3lx: `arb worker stop` on an `:awaiting_review` worker (the
    # documented pre-flight for `arb server deploy`) leaves the issue
    # `in_progress` with no live worker — a state that used to match none of
    # the five columns and vanished from the board entirely.
    test "an in_progress issue with no live worker still shows, flagged for a human" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :in_progress, updated_at: @yesterday, pr_ref: "123"})
          ]
        )

      assert [%{id: "bd-a", reason: reason, mr_ref: "123", needs_you: true}] = board.waiting
      assert reason =~ "worker stopped"

      refute Enum.any?([board.backlog, board.ready, board.running, board.closed_today], fn col ->
               "bd-a" in ids(col)
             end)
    end

    test "an in_progress epic with no live worker is not treated as orphaned" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :in_progress, updated_at: @yesterday, issue_type: :epic})
          ]
        )

      assert board.waiting == []
    end

    test "an in_progress issue that just started dispatch is not flagged orphaned yet" do
      board = derive(issues: [issue("bd-a", %{status: :in_progress, updated_at: @now})])

      assert board.waiting == []
    end

    test "an in_progress issue with a live worker is not double-counted as orphaned" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [worker("bd-a", :awaiting_review, %{mr_ref: "!7"})]
        )

      assert ids(board.waiting) == ["bd-a"]
    end
  end

  # bd-8jixav: a task's own `:awaiting_review` row and a subordinate
  # `:fixpass` / `:conflict` pass's `:failed` row are BOTH in
  # `@waiting_statuses`, so one task rendered as two cards in the Waiting
  # column — read at a glance as two different stuck tickets.
  describe "waiting column, one card per task" do
    test "a subordinate pass does not add a second card for the same task" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{
              mr_ref: "!42",
              step_started_at: @yesterday
            }),
            worker("bd-a", :failed, %{
              registry_key: "bd-a:fixpass",
              role: :fix_pass,
              step_started_at: @now,
              meta: %{stop_reason: %{category: :exited_without_done, summary: "fix pass died"}}
            })
          ]
        )

      assert ids(board.waiting) == ["bd-a"]
    end

    test "the primary row's fields win over the subordinate pass's" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              registry_key: "bd-a:conflict",
              role: :conflict,
              step_started_at: @now
            }),
            worker("bd-a", :awaiting_review, %{
              mr_ref: "!42",
              merger_url: "https://example.test/42",
              step_started_at: @yesterday
            })
          ]
        )

      assert [%{id: "bd-a", status: :awaiting_review, mr_ref: "!42", since: @yesterday}] =
               board.waiting
    end

    test "a subordinate pass with no primary row still gets its own card" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ]
        )

      assert [%{id: "bd-a", status: :failed}] = board.waiting
    end

    test "a collapsed dead fix pass still flags the card and names itself" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{
              mr_ref: "!42",
              registry_key: "bd-a",
              meta: %{last_merger_status: %{status: :ci_failed}}
            }),
            worker("bd-a", :failed, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ],
          watchdog_live: MapSet.new(["bd-a"])
        )

      # The primary alone would read as "the machine is clearing a CI block" —
      # but the pass that clears it is dead.
      assert [%{id: "bd-a", status: :awaiting_review, needs_you: true, collapsed_note: note}] =
               board.waiting

      assert note =~ "fix pass"
      assert note =~ "failed"
    end

    test "a collapsed healthy row adds no note and no flag" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{mr_ref: "!42", registry_key: "bd-a"}),
            worker("bd-a", :awaiting_review, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ],
          watchdog_live: MapSet.new(["bd-a"])
        )

      assert [%{id: "bd-a", needs_you: false, collapsed_note: nil}] = board.waiting
    end

    test "distinct tasks are never collapsed" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{mr_ref: "!1", step_started_at: @yesterday}),
            worker("bd-b", :awaiting_review, %{mr_ref: "!2", step_started_at: @now})
          ]
        )

      assert ids(board.waiting) == ["bd-a", "bd-b"]
    end
  end

  # bd-8jixav: a Watchdog is a :temporary child — when it crashes it is gone
  # for good, silently, and the parked card looks exactly like a healthy one.
  describe "watchdog liveness on a waiting card" do
    test "an :awaiting_review card whose watchdog is gone says so, and flags for a human" do
      board =
        derive(
          workers: [worker("bd-a", :awaiting_review, %{mr_ref: "!42"})],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-a", watchdog_alive: false, needs_you: true}] = board.waiting
    end

    test "an :awaiting_review card with a live watchdog is unflagged and marked alive" do
      board =
        derive(
          workers: [worker("bd-a", :awaiting_review, %{mr_ref: "!42"})],
          watchdog_live: MapSet.new(["bd-a"])
        )

      assert [%{id: "bd-a", watchdog_alive: true, needs_you: false}] = board.waiting
    end

    # A :failed / :awaiting worker has no MR and is not supposed to have a
    # Watchdog, so "no watchdog" is not a finding about it.
    test "a non-review park reports liveness as unknown, not missing" do
      board =
        derive(
          workers: [worker("bd-a", :failed, %{})],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-a", watchdog_alive: nil}] = board.waiting
    end

    # `derive/1` is pure: liveness is a Registry read, so it is an *input*.
    # Callers that don't supply it get "unknown" rather than a false alarm.
    test "omitting the liveness input reports unknown rather than missing" do
      board = derive(workers: [worker("bd-a", :awaiting_review, %{mr_ref: "!42"})])

      assert [%{id: "bd-a", watchdog_alive: nil, needs_you: false}] = board.waiting
    end

    test "an orphaned issue card carries the field too, as unknown" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress, updated_at: @yesterday})],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-a", watchdog_alive: nil}] = board.waiting
    end
  end

  # The flag is not "which status" — it is "has the system run out of things to
  # try on its own", read off each Waiting card.
  defp flags(board), do: Map.new(board.waiting, &{&1.id, &1.needs_you})

  describe "the needs-you flag" do
    test "a worker that asked a human a question always flags" do
      board = derive(workers: [worker("bd-a", :awaiting, %{meta: %{await_reason: "which?"}})])

      assert flags(board) == %{"bd-a" => true}
    end

    test "a merge request the forge is still chewing on does not flag" do
      board =
        derive(
          workers: [
            worker("bd-a", :awaiting_review, %{meta: %{last_merger_status: %{approved: false}}}),
            worker("bd-b", :awaiting_review, %{meta: %{}})
          ]
        )

      assert flags(board) == %{"bd-a" => false, "bd-b" => false}
    end

    test "an approved merge request blocked on anything the Watchdog cannot clear flags" do
      board =
        derive(
          workers:
            for {id, reason} <- [
                  {"bd-a", :conflict},
                  {"bd-b", :needs_approval},
                  {"bd-c", :needs_nonauthor_approval},
                  # Nothing in Arbiter takes a PR out of draft or resolves a
                  # forge-specific block, so these are the operator's too.
                  {"bd-d", :draft},
                  {"bd-e", :blocked_other}
                ] do
              worker(id, :awaiting_review, %{
                meta: %{last_merger_status: %{approved: true, block_reason: reason}}
              })
            end
        )

      assert flags(board) == %{
               "bd-a" => true,
               "bd-b" => true,
               "bd-c" => true,
               "bd-d" => true,
               "bd-e" => true
             }
    end

    test "a block the system still auto-handles does not flag" do
      board =
        derive(
          workers:
            for {id, reason} <- [{"bd-a", :behind_base}, {"bd-b", :ci_failed}] do
              worker(id, :awaiting_review, %{
                meta: %{last_merger_status: %{approved: true, block_reason: reason}}
              })
            end
        )

      assert flags(board) == %{"bd-a" => false, "bd-b" => false}
    end

    test "a parked failure with nothing left in flight flags" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            })
          ]
        )

      assert flags(board) == %{"bd-a" => true}
    end

    # A review-timeout failure keeps the last poll's merger status in its meta,
    # so a terminal worker can still be carrying an auto-resolvable block. The
    # worker is dead either way — the status wins over the stale block.
    test "a parked failure flags even carrying a stale auto-resolvable block" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              meta: %{last_merger_status: %{approved: true, block_reason: :ci_failed}}
            })
          ]
        )

      assert flags(board) == %{"bd-a" => true}
    end
  end

  # bd-9so315 — merged-but-unverified tasks are the coordinator's: nothing else
  # will clear them, so they belong in Waiting alongside the other cards that
  # need a human.
  describe "awaiting-verification cards" do
    test "a parked task appears in Waiting with its age and needs_you" do
      board =
        derive(
          issues: [
            issue("bd-v", %{
              status: :awaiting_verification,
              awaiting_verification_at: @yesterday
            })
          ]
        )

      assert [card] = board.waiting
      assert card.id == "bd-v"
      assert card.status == :awaiting_verification
      assert card.needs_you == true
      assert card.since == @yesterday
      assert card.reason =~ "verif"
    end

    test "falls back to updated_at when the stamp predates the field" do
      board =
        derive(
          issues: [
            issue("bd-v", %{status: :awaiting_verification, updated_at: @yesterday})
          ]
        )

      assert [%{since: @yesterday}] = board.waiting
    end

    test "an open or closed task produces no awaiting card" do
      board =
        derive(issues: [issue("bd-a"), issue("bd-b", %{status: :closed, updated_at: @now})])

      assert board.waiting == []
    end

    test "a parked task is not also a Ready or Backlog card" do
      board = derive(issues: [issue("bd-v", %{status: :awaiting_verification})])

      assert ids(board.ready) == []
      assert ids(board.backlog) == []
    end
  end

  describe "closed recent column (last 24 hours)" do
    test "includes issues closed within the last 24 hours, newest-closed first" do
      # @now = 2026-08-22 12:00:00 UTC
      # 13h ago (within 24h, yesterday): 2026-08-21 23:00:00 UTC
      # 20h ago (within 24h): 2026-08-21 16:00:00 UTC
      # 23h ago (within 24h): 2026-08-21 13:00:00 UTC
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-21 13:00:00Z]}),
            issue("bd-b", %{status: :closed, closed_at: ~U[2026-08-21 16:00:00Z]}),
            issue("bd-c", %{status: :closed, closed_at: ~U[2026-08-21 23:00:00Z]})
          ]
        )

      # Should include all (all are within 24h), sorted newest-closed first
      assert ids(board.closed_today) == ["bd-c", "bd-b", "bd-a"]
    end

    test "excludes issues closed more than 24 hours ago" do
      # @now = 2026-08-22 12:00:00 UTC
      # 25h ago (beyond 24h): 2026-08-21 11:00:00 UTC
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-21 11:00:00Z]}),
            issue("bd-b", %{status: :closed, closed_at: ~U[2026-08-22 11:00:00Z]})
          ]
        )

      # Should exclude bd-a (25h ago), include bd-b (1h ago)
      assert ids(board.closed_today) == ["bd-b"]
    end

    test "does not include recently updated issues closed more than 24h ago" do
      # @now = 2026-08-22 12:00:00 UTC
      # Closed 30h ago but updated 1h ago: should NOT be included
      board =
        derive(
          issues: [
            issue("bd-a", %{
              status: :closed,
              closed_at: ~U[2026-08-21 06:00:00Z],
              updated_at: ~U[2026-08-22 11:00:00Z]
            })
          ]
        )

      # Should be empty (closed_at is what matters, not updated_at)
      assert ids(board.closed_today) == []
    end

    test "falls back to updated_at for legacy issues with nil closed_at" do
      # For backward compatibility, if closed_at is nil, use updated_at
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, closed_at: nil, updated_at: ~U[2026-08-22 11:00:00Z]})
          ]
        )

      # Should include it because updated_at is within 24h
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excludes legacy issues with nil closed_at updated more than 24h ago" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, closed_at: nil, updated_at: ~U[2026-08-21 11:00:00Z]})
          ]
        )

      # Should exclude it because even updated_at is beyond 24h
      assert ids(board.closed_today) == []
    end

    # bd-38of5i (design bd-2s901b §4): an epic is a rollup of children, not a
    # piece of work — so "the day's evidence of progress" is the children that
    # closed, not the container that closed because they did. Closed-today was
    # the one column epics still leaked into; every other column already
    # excludes them via `queueable?/2` / `orphaned?/3`.
    test "an epic closed in the last 24h is not a Closed card" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{
              issue_type: :epic,
              status: :closed,
              closed_at: ~U[2026-08-22 11:00:00Z]
            }),
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-22 10:00:00Z]})
          ]
        )

      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excluding the epic leaves every other column, the counts and the slot math alone" do
      issues = [
        issue("bd-epic", %{issue_type: :epic, status: :closed, closed_at: @now}),
        issue("bd-ready"),
        issue("bd-backlog", %{refined: false}),
        issue("bd-run", %{status: :in_progress}),
        issue("bd-closed", %{status: :closed, closed_at: @now})
      ]

      board = derive(issues: issues, workers: [worker("bd-run", :running)])

      assert ids(board.backlog) == ["bd-backlog"]
      assert Enum.map(board.ready, & &1.card.id) == ["bd-ready"]
      assert ids(board.running) == ["bd-run"]
      assert board.waiting == []
      assert ids(board.closed_today) == ["bd-closed"]
      assert board.slots_total == 4
      assert board.slots_free == 3
    end
  end

  # bd-38of5i (design bd-2s901b §4): with epics gone from every column, a
  # child card is the only place an epic stays discoverable on the board — so
  # every card carries a ref to its parent for the view to render as a chip.
  # bd-8j9i9p (design bd-9jj5lf §3): a task whose worker spend has passed its
  # difficulty/type group's p90 is not a stuck worker, but it is a thing to
  # look at — so it flags on the board the way `needs_you` does. The estimate
  # itself is an *input* here: `derive/1` never reads the ledger.
  describe "over-budget attention flag" do
    test "an open issue in the over-budget set flags on its card" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          over_budget: ["bd-a"]
        )

      assert [%{card: %{id: "bd-a", over_budget: true}}, %{card: %{over_budget: false}}] =
               board.ready
    end

    test "every open column carries the flag" do
      board =
        derive(
          issues: [
            issue("bd-backlog", %{refined: false}),
            issue("bd-ready"),
            issue("bd-run", %{status: :in_progress}),
            issue("bd-wait", %{status: :in_progress, updated_at: @yesterday})
          ],
          workers: [worker("bd-run", :running)],
          over_budget: ["bd-backlog", "bd-ready", "bd-run", "bd-wait"]
        )

      assert [%{over_budget: true}] = board.backlog
      assert [%{card: %{over_budget: true}}] = board.ready
      assert [%{over_budget: true}] = board.running
      assert [%{over_budget: true}] = board.waiting
    end

    test "a closed card never flags, even if its id is in the set" do
      board =
        derive(
          issues: [issue("bd-closed", %{status: :closed, closed_at: @now})],
          over_budget: ["bd-closed"]
        )

      assert [%{over_budget: false}] = board.closed_today
    end

    test "no over-budget input means no card flags" do
      board = derive(issues: [issue("bd-a")])

      assert [%{card: %{over_budget: false}}] = board.ready
    end
  end

  describe "parent ref on cards" do
    test "a card whose issue has a parent_of parent carries the parent's id, title and progress" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{issue_type: :epic, title: "Browser sessions"}),
            issue("bd-a"),
            issue("bd-b", %{status: :closed, closed_at: @now})
          ],
          parent_of: [parent_of("bd-epic", "bd-a"), parent_of("bd-epic", "bd-b")]
        )

      assert [%{card: %{parent: parent}}] = board.ready

      assert parent == %{
               id: "bd-epic",
               title: "Browser sessions",
               issue_type: :epic,
               child_total: 2,
               child_closed: 1
             }
    end

    test "a card whose issue has no parent carries a nil parent" do
      board = derive(issues: [issue("bd-a")])

      assert [%{card: %{parent: nil}}] = board.ready
    end

    test "every column's cards carry the ref, not just Ready" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{issue_type: :epic, title: "Epic"}),
            issue("bd-backlog", %{refined: false}),
            issue("bd-run", %{status: :in_progress}),
            issue("bd-wait", %{status: :in_progress, updated_at: @yesterday}),
            issue("bd-closed", %{status: :closed, closed_at: @now})
          ],
          workers: [worker("bd-run", :running)],
          parent_of: [
            parent_of("bd-epic", "bd-backlog"),
            parent_of("bd-epic", "bd-run"),
            parent_of("bd-epic", "bd-wait"),
            parent_of("bd-epic", "bd-closed")
          ]
        )

      assert [%{parent: %{id: "bd-epic"}}] = board.backlog
      assert [%{parent: %{id: "bd-epic"}}] = board.running
      assert [%{parent: %{id: "bd-epic"}}] = board.waiting
      assert [%{parent: %{id: "bd-epic"}}] = board.closed_today
    end

    # Multiple parents are unusual but legal. A card has room for one chip, so
    # it takes the most recently updated parent — the same tie-break the
    # detail-page banner stacks by.
    test "with more than one parent, the card takes the most recently updated one" do
      board =
        derive(
          issues: [
            issue("bd-old", %{issue_type: :epic, updated_at: @yesterday}),
            issue("bd-new", %{issue_type: :epic, updated_at: @now}),
            issue("bd-a")
          ],
          parent_of: [parent_of("bd-old", "bd-a"), parent_of("bd-new", "bd-a")]
        )

      assert [%{card: %{parent: %{id: "bd-new"}}}] = board.ready
    end

    # A parent_of row pointing at an issue the board never read is a dangling
    # edge, not a chip: better no chip than one that links to a 404 with a
    # blank title.
    test "a parent the board did not read produces no ref" do
      board = derive(issues: [issue("bd-a")], parent_of: [parent_of("bd-gone", "bd-a")])

      assert [%{card: %{parent: nil}}] = board.ready
    end

    # A non-epic parent (a plain task with subtasks) still gets a chip; the
    # component renders it without the epic chrome.
    test "a non-epic parent still produces a ref, carrying its own type" do
      board =
        derive(
          issues: [issue("bd-parent", %{issue_type: :task}), issue("bd-a")],
          parent_of: [parent_of("bd-parent", "bd-a")]
        )

      assert %{card: %{parent: %{id: "bd-parent", issue_type: :task}}} =
               Enum.find(board.ready, &(&1.card.id == "bd-a"))
    end
  end

  describe "board-wide holds" do
    test "an exhausted quota blocks promotion and names itself" do
      board = derive(issues: [issue("bd-a")], quota: {:hold, "quota exhausted"})

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — quota exhausted"}] = board.ready
    end

    test "a paused board dispatches nothing" do
      board = derive(issues: [issue("bd-a")], paused: true)

      assert board.promote == nil
      assert [%{state: :blocked, reason: "scheduler paused"}] = board.ready
    end
  end

  # bd-1273p2: an epic detail page groups its children into the same five
  # columns the board renders, using this helper so the two surfaces can't
  # drift onto different classifications.
  describe "classify_columns/2" do
    test "an unrefined open issue lands in backlog" do
      assert Snapshot.classify_columns([issue("bd-a", %{refined: false})]) == %{
               "bd-a" => :backlog
             }
    end

    test "a refined open issue lands in ready" do
      assert Snapshot.classify_columns([issue("bd-a", %{refined: true})]) == %{"bd-a" => :ready}
    end

    test "an in-progress issue with a live running worker lands in running" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :running)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "a worker's presence outranks a stale open status, same as the board" do
      issues = [issue("bd-a", %{status: :open})]
      workers = [worker("bd-a", :idle)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "an in-progress issue with a parked worker lands in waiting" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :awaiting_review)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "an in-progress issue with no worker at all lands in waiting" do
      issues = [issue("bd-a", %{status: :in_progress})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "an awaiting_verification issue lands in waiting" do
      issues = [issue("bd-a", %{status: :awaiting_verification})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "a closed issue lands in closed" do
      issues = [issue("bd-a", %{status: :closed})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :closed}
    end

    test "a reviewer/implementer worker on the same task does not count as running" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :running, %{meta: %{role: :reviewer}})]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "classifies a full mix of issues independently" do
      issues = [
        issue("bd-backlog", %{refined: false}),
        issue("bd-ready", %{refined: true}),
        issue("bd-running", %{status: :in_progress}),
        issue("bd-waiting", %{status: :in_progress}),
        issue("bd-closed", %{status: :closed})
      ]

      workers = [worker("bd-running", :running)]

      assert Snapshot.classify_columns(issues, workers) == %{
               "bd-backlog" => :backlog,
               "bd-ready" => :ready,
               "bd-running" => :running,
               "bd-waiting" => :waiting,
               "bd-closed" => :closed
             }
    end
  end
end
