defmodule ArbiterWeb.TaskDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  # A minimal real GenServer double for `Arbiter.Worker`, registered under the
  # same registry key a live worker uses, answering the `:snapshot` call
  # `Worker.state/1` makes. Enough for the page to see a run as live and to
  # seed the expanded transcript from `meta.output_lines`.
  defmodule FakeWorker do
    use GenServer

    def start_link(task_id, output_lines) do
      GenServer.start_link(__MODULE__, output_lines,
        name: Arbiter.Worker.Registry.via_tuple(task_id)
      )
    end

    @impl true
    def init(output_lines), do: {:ok, output_lines}

    @impl true
    def handle_call(:snapshot, _from, lines) do
      {:reply, %{status: :running, started_at: DateTime.utc_now(), meta: %{output_lines: lines}},
       lines}
    end
  end

  # A worker double that reports a live agent session, so `Dispatch.dispatch/2`
  # hits the bd-2aslx6 guard without a real CLI subprocess. `:running` keeps it
  # out of the terminal-worker exemption the guard grants a stale worker.
  defmodule FakeLiveAgentWorker do
    use GenServer

    def start_link(task_id) do
      GenServer.start_link(__MODULE__, :ok, name: Arbiter.Worker.Registry.via_tuple(task_id))
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:agent_session_live?, _from, state), do: {:reply, true, state}

    def handle_call(:snapshot, _from, state) do
      {:reply, %{status: :running, started_at: DateTime.utc_now(), meta: %{}}, state}
    end
  end

  setup do
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "bd-ws-#{System.unique_integer([:positive])}", prefix: "bdt"})

    {:ok, ws: ws}
  end

  describe "GET /tasks/:id" do
    test "renders the task with workspace, status, and history", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "important thing",
          description: "do the thing",
          workspace_id: ws.id,
          priority: 1
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ task.id
      assert html =~ "important thing"
      assert html =~ "do the thing"
      assert html =~ ws.name
      # History section shows the :create version.
      assert html =~ "History"
      assert html =~ "create"
    end

    test "renders blocked-by + blocks dependency sections by semantic role, not raw direction",
         %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      # a blocks b (a is the blocker, b is blocked).
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      {:ok, _view, a_html} = live(conn, ~p"/tasks/#{a.id}")

      assert a_html =~ "Blocks (1)"
      assert a_html =~ b.id
      assert a_html =~ "B"
      refute a_html =~ "Blocked by ("

      {:ok, _view, b_html} = live(conn, ~p"/tasks/#{b.id}")

      assert b_html =~ "Blocked by (1)"
      assert b_html =~ a.id
      assert b_html =~ "A"
      refute b_html =~ "Blocks ("
    end

    test "shows worker info inline when one is running", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "polly", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Worker"
      assert html =~ "idle"
      assert html =~ "view full output"
    end

    # Regression for bd-bb9fev: a worker snapshot without `:claude_session?`
    # used to crash render/1 with BadBooleanError because the strict `and`
    # operator rejected a nil left operand.
    test "renders when the worker snapshot has no :claude_session? field",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no-claude", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ task.id
      assert html =~ "Worker"
    end

    test "tells the user when no worker is running", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "lonely", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "No worker running"
      assert html =~ "arb dispatch"
    end

    test "404-ish state when task doesn't exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks/bdt-doesnotexist")
      assert html =~ "not found"
    end

    test "long task title is truncated and doesn't cause page overflow", %{conn: conn, ws: ws} do
      long_title =
        "This is a very long task title that is definitely longer than one hundred characters and should be truncated with an ellipsis to prevent it from overflowing the page"

      {:ok, task} =
        Ash.create(Issue, %{
          title: long_title,
          description: "do the thing",
          workspace_id: ws.id
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ long_title
      # Verify the h1 has the truncate class
      assert html =~ ~r/<h1[^>]*class="[^"]*truncate[^"]*"[^>]*>/
      # Verify the title attribute is set for tooltip
      assert html =~ ~r/title="#{Regex.escape(long_title)}"/
    end

    test "re-renders when a relevant task_lifecycle fires", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "transitioning", workspace_id: ws.id})

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "open"

      {:ok, _} = Ash.update(task, %{status: :in_progress})

      assert render(view) =~ "in_progress"
    end
  end

  # bd-9so315 — the task page is where the verification evidence lives, and
  # where the board's "verify" chip sends the coordinator.
  describe "post-merge verification" do
    test "a parked task says it is awaiting verification and how to record it", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "doctor probe",
          workspace_id: ws.id,
          verify_after_deploy: true
        })

      {:ok, _} = Ash.update(task, %{}, action: :await_verification)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "awaiting_verification"
      assert html =~ "arb issue verify"
    end

    test "a recorded verdict shows the outcome and the evidence", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "capture", workspace_id: ws.id, verify_after_deploy: true})

      {:ok, awaiting} = Ash.update(task, %{}, action: :await_verification)

      {:ok, _closed} =
        Arbiter.Tasks.Verification.observed(awaiting, "restarted 14:02; the new path fires")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "restarted 14:02; the new path fires"
      assert html =~ "observed"
    end

    test "an unflagged task shows no verification section", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "ordinary", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "arb issue verify"
    end
  end

  describe "Merge section — prior MR history (bd-6h4ia3)" do
    defp create_run(task, mr_ref, started_at) do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          status: :completed,
          started_at: started_at,
          mr_ref: mr_ref
        })

      run
    end

    test "single worker run with one MR shows no history clutter", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "one mr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#100"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "#100"
      refute html =~ "Prior MRs"
    end

    test "multiple runs opening genuinely different MRs show all, most recent first", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "many mrs", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#300"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])
      create_run(task, "#200", ~U[2026-07-02 00:00:00.000000Z])
      create_run(task, "#300", ~U[2026-07-03 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Prior MRs"
      assert html =~ "#100"
      assert html =~ "#200"
      assert html =~ "#300"

      idx200 = :binary.match(html, "#200") |> elem(0)
      idx100 = :binary.match(html, "#100") |> elem(0)
      assert idx200 < idx100
    end

    test "task resumed multiple times against the same MR shows it once", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "resumed same mr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#100"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])
      create_run(task, "#100", ~U[2026-07-02 00:00:00.000000Z])
      create_run(task, "#100", ~U[2026-07-03 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert (html |> String.split("#100") |> length()) - 1 == 1
      refute html =~ "Prior MRs"
    end
  end

  describe "repo assignment (bd-2jum8j)" do
    test "the detail rail names the task's own repo over any run/workspace guess",
         %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rail-repo-ws-#{System.unique_integer([:positive])}",
          prefix: "rrw",
          config: %{"repo_paths" => %{"org/alpha" => "/tmp/arb-a", "org/beta" => "/tmp/arb-b"}}
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "assigned", workspace_id: ws.id, repo: "org/beta"})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "org/beta"
    end

    test "the dispatch modal's blank repo choice names the task's assignment",
         %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "modal-repo-ws-#{System.unique_integer([:positive])}",
          prefix: "mrw",
          config: %{"repo_paths" => %{"org/alpha" => "/tmp/arb-a", "org/beta" => "/tmp/arb-b"}}
        })

      {:ok, assigned} =
        Ash.create(Issue, %{title: "assigned", workspace_id: ws.id, repo: "org/beta"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{assigned.id}")
      html = view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()
      assert html =~ "Task default (org/beta)"

      # bd-9dwbvt: `:create` now binds a repo, so an unassigned task is built
      # the way one survives in the wild — filed with a repo, then cleared.
      {:ok, unassigned} =
        Ash.create(Issue, %{title: "unassigned", workspace_id: ws.id, repo: "org/alpha"})

      {:ok, unassigned} = Ash.update(unassigned, %{repo: nil})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{unassigned.id}")
      html = view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()
      assert html =~ "Workspace default"
    end

    test "the ambiguous-repo failure points at assigning the task a repo", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ambig-repo-ws-#{System.unique_integer([:positive])}",
          prefix: "arw",
          config: %{"repo_paths" => %{"org/alpha" => "/tmp/arb-a", "org/beta" => "/tmp/arb-b"}}
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "ambiguous", workspace_id: ws.id, repo: "org/alpha"})

      # bd-9dwbvt: dispatch's ambiguity only arises for a task with no repo,
      # which is now a post-create state rather than a creatable one.
      {:ok, task} = Ash.update(task, %{repo: nil})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      view
      |> form("#task-dispatch-form", %{
        "dispatch" => %{"provider" => "", "repo" => "", "acknowledge" => "true"}
      })
      |> render_submit()

      assert render_async(view) =~ "assign this task a repo"
    end
  end

  describe "edit" do
    test "the Edit button opens the modal and saving writes the fields", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "before", workspace_id: ws.id, priority: 3})

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ ~s(id="task-edit-modal")

      html = view |> element(~s(button[phx-click="open_edit"])) |> render_click()
      assert html =~ ~s(id="task-edit-modal")

      html =
        view
        |> form("#task-edit-form", %{
          "task" => %{
            "title" => "after",
            "status" => "in_progress",
            "priority" => "1",
            "difficulty" => "4",
            "issue_type" => "chore",
            "target_branch" => "release/x",
            "description" => "rewritten body",
            "acceptance" => "it works"
          }
        })
        |> render_submit()

      assert html =~ "after"
      assert html =~ "rewritten body"
      refute html =~ ~s(id="task-edit-modal")

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.title == "after"
      assert reloaded.status == :in_progress
      assert reloaded.priority == 1
      assert reloaded.difficulty == 4
      assert reloaded.issue_type == :chore
      assert reloaded.target_branch == "release/x"
      assert reloaded.acceptance == "it works"
    end

    test "the edit modal assigns the task's repo from the configured repo list (bd-2jum8j)",
         %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "edit-repo-ws-#{System.unique_integer([:positive])}",
          prefix: "erw",
          config: %{
            "repo_paths" => %{
              "org/alpha" => "/tmp/arb-resolvable",
              "pathless-repo" => %{"target_branch" => "main"}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "unassigned", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="open_edit"])) |> render_click()

      # Same source of truth as the dispatch modal: an unresolvable repo_paths
      # entry must never be offered as an assignment.
      assert html =~ "org/alpha"
      refute html =~ "pathless-repo"

      view
      |> form("#task-edit-form", %{"task" => %{"title" => "unassigned", "repo" => "org/alpha"}})
      |> render_submit()

      assert Ash.get!(Issue, task.id).repo == "org/alpha"

      # And clearing it back to "no assignment" nulls the column rather than
      # storing an empty string.
      view |> element(~s(button[phx-click="open_edit"])) |> render_click()

      view
      |> form("#task-edit-form", %{"task" => %{"title" => "unassigned", "repo" => ""}})
      |> render_submit()

      assert Ash.get!(Issue, task.id).repo == nil
    end

    test "a blank title is refused and the modal stays open", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "keep-me", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_edit"])) |> render_click()

      html =
        view
        |> form("#task-edit-form", %{"task" => %{"title" => "  "}})
        |> render_submit()

      assert html =~ "Title can&#39;t be empty."
      assert html =~ ~s(id="task-edit-modal")

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.title == "keep-me"
    end

    # LiveView preserves only the focused input across a re-render, so a
    # rejected save used to snap every other field back to the persisted
    # record — losing a freshly-rewritten description.
    test "a rejected save re-renders what was typed", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "keep-me",
          description: "the old body",
          workspace_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_edit"])) |> render_click()

      html =
        view
        |> form("#task-edit-form", %{
          "task" => %{"title" => "  ", "description" => "a rewritten body worth keeping"}
        })
        |> render_submit()

      # Only the edit textarea can be the source of this string — the page
      # body still renders the (unchanged) persisted description.
      assert html =~ "a rewritten body worth keeping"
      assert html =~ ~s(id="task-edit-modal")
    end

    test "a closed task offers no Edit action", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "done", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ ~s(phx-click="open_edit")
    end

    # The edit/close/dispatch modals still use daisyUI markup (`btn`,
    # `alert`), on purpose — they haven't been redesigned. bd-3z2txy dropped
    # the CoreComponents.button/1 & .icon/1 shadowing shim, so `<.button>`
    # and `<.icon>` now resolve to the design-handoff Core versions; these
    # call sites must stay explicitly qualified to the old
    # `ArbiterWeb.CoreComponents` module or they'd silently pick up the
    # handoff component's markup (a CSS-variable class list and inline
    # width/height style) instead of daisyUI's.
    test "the edit modal buttons keep daisyUI markup, not the handoff Core button", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "before", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="open_edit"])) |> render_click()

      assert html =~ ~s(class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit")
      assert html =~ ~s(class="btn btn-sm btn-primary" type="submit")
    end

    # bd-9so315: the status select only offers the statuses `:update` accepts,
    # so a parked task's own status was not among them — the browser would fall
    # back to the first option and an edit that never meant to touch status
    # would try an illegal transition and fail the whole save.
    test "editing a parked task keeps its status instead of silently resetting it", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} =
        Ash.create(Issue, %{title: "parked", workspace_id: ws.id, verify_after_deploy: true})

      {:ok, parked} = Ash.update(task, %{}, action: :await_verification)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parked.id}")
      html = view |> element(~s(button[phx-click="open_edit"])) |> render_click()
      assert html =~ "awaiting_verification"

      view
      |> form("#task-edit-form", %{
        "task" => %{
          "title" => "parked, retitled",
          "status" => "awaiting_verification",
          "priority" => "2",
          "difficulty" => "2",
          "issue_type" => "feature"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(Issue, parked.id)
      assert reloaded.title == "parked, retitled"
      assert reloaded.status == :awaiting_verification
    end
  end

  describe "close" do
    test "closing with a reason closes the task and records the reason",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "closeable", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="open_close"])) |> render_click()
      assert html =~ ~s(id="task-close-modal")

      html =
        view
        |> form("#task-close-form", %{"close" => %{"reason" => "superseded by bd-other"}})
        |> render_submit()

      assert html =~ "closed"

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
      assert reloaded.closed_at
    end

    test "an already-closed task offers no Close action", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "already", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ ~s(phx-click="open_close")
    end
  end

  # bd-b5wyjd — the one door out of Backlog. Deliberately not a checklist gate:
  # the button is always clickable, whatever fields are still empty.
  describe "promote to Ready" do
    test "an unrefined task offers the promote action", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "raw", workspace_id: ws.id})
      refute task.refined

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Move to Ready"
      assert has_element?(view, ~s(button[phx-click="promote_to_ready"]))
    end

    test "clicking it refines the task and the action goes away", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "refine me", workspace_id: ws.id, acceptance: "- it works"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.refined
      assert reloaded.status == :open

      refute html =~ ~s(phx-click="promote_to_ready")
    end

    test "an already-refined task offers no promote action", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "already refined",
          workspace_id: ws.id,
          acceptance: "- it works"
        })

      {:ok, _} = Ash.update(task, %{}, action: :promote_to_ready)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s(phx-click="promote_to_ready")
    end

    test "a closed task offers no promote action, refined or not", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "dead idea", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s(phx-click="promote_to_ready")
    end

    test "an empty task with no description still promotes — Backlog is not a completeness gate",
         %{conn: conn, ws: ws} do
      # bd-7mbrlg: acceptance criteria is the one exception (below); an empty
      # description doesn't gate promotion at all.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "no description",
          workspace_id: ws.id,
          acceptance: "- it works"
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.refined
    end

    test "an in_progress task offers no promote action even if unrefined", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "running now", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ ~s(phx-click="promote_to_ready")
    end

    # bd-7mbrlg — the acceptance-criteria gate and its waiver modal.
    test "a bug with no acceptance criteria opens the waiver modal instead of promoting",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "no ACs", workspace_id: ws.id, issue_type: :bug})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      assert html =~ "Promote without acceptance criteria"
      assert has_element?(view, "#task-promote-waiver-form")

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.refined
    end

    test "submitting the waiver form with a reason promotes and persists the reason",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "no ACs", workspace_id: ws.id, issue_type: :feature})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      html =
        view
        |> form("#task-promote-waiver-form", waiver: %{reason: "spike, no user-facing change"})
        |> render_submit()

      refute html =~ "Promote without acceptance criteria"
      assert html =~ "ACCEPTANCE WAIVED"
      assert html =~ "spike, no user-facing change"

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.refined
      assert reloaded.acceptance_waived == "spike, no user-facing change"
    end

    test "submitting the waiver form with a blank reason keeps the modal open with an error",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "no ACs", workspace_id: ws.id, issue_type: :chore})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      html =
        view
        |> form("#task-promote-waiver-form", waiver: %{reason: "   "})
        |> render_submit()

      assert html =~ "reason for waiving"

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.refined
    end

    test "a task/decision/epic with no acceptance criteria promotes directly (exempt)",
         %{conn: conn, ws: ws} do
      for type <- [:task, :decision, :epic] do
        {:ok, task} =
          Ash.create(Issue, %{title: "exempt #{type}", workspace_id: ws.id, issue_type: type})

        {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
        view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

        {:ok, reloaded} = Ash.get(Issue, task.id)
        assert reloaded.refined
      end
    end

    test "D0 work promotes directly with an auto-waiver, no modal", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "trivial",
          workspace_id: ws.id,
          issue_type: :chore,
          difficulty: 0
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      refute html =~ "Promote without acceptance criteria"

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.refined
      assert reloaded.acceptance_waived =~ "D0"
    end
  end

  describe "dispatch" do
    test "no dispatch action while a worker is already running", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "busy", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      refute html =~ ~s(phx-click="open_dispatch")
    end

    test "the Dispatch button opens a modal that warns about API credits",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "dispatchable", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      assert html =~ ~s(id="task-dispatch-modal")
      assert html =~ "API credits"
    end

    # The acknowledgement checkbox IS the confirmation step: submitting without
    # it must not reach Dispatch at all (no credits spent, task untouched).
    test "dispatch without the acknowledgement is refused", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "unacked", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      html =
        view
        |> form("#task-dispatch-form", %{
          "dispatch" => %{"provider" => "claude", "repo" => "", "acknowledge" => "false"}
        })
        |> render_submit()

      assert html =~ "Confirm you understand"
      assert html =~ ~s(id="task-dispatch-modal")

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
    end

    # With the acknowledgement ticked the real dispatch path runs. This
    # workspace has no repos configured, so it fails at repo resolution —
    # before any agent is spawned — which is exactly the proof the LiveView
    # calls the same Dispatch entry point the CLI/MCP use.
    #
    # Dispatch runs in start_async/3 (it shells out to the provider CLI for the
    # auth preflight, so it must not block the LiveView process), hence the
    # submit itself only shows the pending state and the outcome lands after.
    test "an acknowledged dispatch reaches the real dispatch path", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "acked", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      pending =
        view
        |> form("#task-dispatch-form", %{
          "dispatch" => %{"provider" => "claude", "repo" => "", "acknowledge" => "true"}
        })
        |> render_submit()

      assert pending =~ ~s(id="task-dispatch-pending")

      html = render_async(view)

      assert html =~ "Dispatch failed"
      assert html =~ "repo"
      refute html =~ ~s(id="task-dispatch-pending")
    end

    # bd-2aslx6 (#1428): the Dispatch button hides once a worker is registered,
    # so the refusal is reached by the race the guard exists for — a worker with
    # a live agent session appears between the page render and the submit (a
    # second tab, the scheduler, a CLI dispatch). The operator must read prose,
    # not the raw `{:agent_session_active, "bd-..."}` tuple.
    test "a live agent session is refused with a readable message",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "already live", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      # The worker (and its live session) shows up after the modal is open.
      {:ok, _pid} = FakeLiveAgentWorker.start_link(task.id)

      view
      |> form("#task-dispatch-form", %{
        "dispatch" => %{"provider" => "claude", "repo" => "", "acknowledge" => "true"}
      })
      |> render_submit()

      html = render_async(view)

      assert html =~ "already has a live agent session"
      refute html =~ "agent_session_active"
    end

    # The dropdown must not offer a repo `Dispatch` would then reject with
    # {:repo_not_found, repo} — after the operator has already acknowledged the
    # credit spend. `Dispatch.all_available_repos/1` is the single source of
    # truth for both lists.
    test "the repo dropdown omits repo_paths entries that can't resolve a path",
         %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "repo-ws-#{System.unique_integer([:positive])}",
          prefix: "rpo",
          config: %{
            "repo_paths" => %{
              "resolvable-repo" => "/tmp/arb-resolvable",
              # A real config shape that carries no usable path.
              "pathless-repo" => %{"target_branch" => "main"}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "repo-choices", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      assert html =~ "resolvable-repo"
      refute html =~ "pathless-repo"
    end

    # The provider select can only offer known agents, so this guards the
    # hand-rolled POST: an unknown provider must never reach Dispatch.
    test "an unknown provider is rejected loudly", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "bad-provider", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="open_dispatch"])) |> render_click()

      html =
        render_submit(view, "dispatch", %{
          "dispatch" => %{"provider" => "kodex", "repo" => "", "acknowledge" => "true"}
        })

      assert html =~ "kodex"
    end
  end

  # ── Redesigned screen (bd-289r9h / README §4) ────────────────────────────
  #
  # The task detail screen absorbs the run index and run detail pages: every
  # run that touched this issue is a row in an in-place-expanding roster, and
  # the audit log folds into the Activity stream.
  describe "redesigned shell" do
    test "renders the toolbar breadcrumb, id, status chip and back link",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "shell", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Board / Issues /"
      assert html =~ task.id
      assert html =~ "Back to board"
      assert html =~ ~s(aria-label="Copy issue id #{task.id}")
    end

    test "acceptance criteria render as one real checkbox per line",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "with acceptance",
          acceptance: "- [x] first criterion\n- [ ] second criterion",
          workspace_id: ws.id
        })

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "ACCEPTANCE"
      assert html =~ "first criterion"
      assert html =~ "second criterion"
      # The markdown markers carry the state; they are not literal prose.
      refute html =~ "- [x] first criterion"

      # Real toggles, not decoration: ticking one persists onto the issue by
      # rewriting its markdown marker, so the CLI reads the same state.
      view |> element(~s(input[phx-value-criterion="1"])) |> render_click()

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.acceptance == "- [x] first criterion\n- [x] second criterion"
    end

    # bd-a39f4o §3 IA: the waiver is a sub-state of ACCEPTANCE, not its own
    # panel, so it must render inside #panel-acceptance and there must be no
    # separate waiver panel id.
    test "the acceptance waiver renders inside the acceptance panel, not a separate panel",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "waived", workspace_id: ws.id, issue_type: :bug})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element(~s(button[phx-click="promote_to_ready"])) |> render_click()

      html =
        view
        |> form("#task-promote-waiver-form",
          waiver: %{reason: "spike, no user-facing change"}
        )
        |> render_submit()

      refute html =~ ~s(id="panel-acceptance-waived")
      acceptance_panel = view |> element("#panel-acceptance") |> render()
      assert acceptance_panel =~ "ACCEPTANCE WAIVED"
      assert acceptance_panel =~ "spike, no user-facing change"
    end

    # bd-a39f4o acceptance #1: desktop panel order matches the bd-3uhith IA
    # exactly. Assert via the ids present on each `.panel`, in source order.
    test "desktop panel order follows the redesigned information architecture",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "everything",
          description: "the description",
          acceptance: "- [ ] one",
          notes: "some findings",
          qa_notes: "qa'd",
          issue_type: :task,
          target_branch: "main",
          workspace_id: ws.id
        })

      {:ok, task} = Ash.update(task, %{verify_after_deploy: true})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      main_ids = ~w(
        panel-description panel-acceptance panel-findings panel-merge-review
        panel-qa-deployment panel-runs panel-activity
      )

      rail_ids = ~w(
        panel-current-run panel-verification panel-relationships panel-messages
        panel-machine-state panel-skills
      )

      assert Enum.all?(main_ids, &(html =~ ~s(id="#{&1}")))
      assert Enum.all?(rail_ids, &(html =~ ~s(id="#{&1}")))

      positions_main = Enum.map(main_ids, &panel_position(html, &1))
      assert positions_main == Enum.sort(positions_main)

      positions_rail = Enum.map(rail_ids, &panel_position(html, &1))
      assert positions_rail == Enum.sort(positions_rail)
    end
  end

  describe "run roster (absorbs the run index)" do
    setup %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "rostered", workspace_id: ws.id})

      {:ok, main} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :main,
          status: :completed,
          started_at: ~U[2026-07-01 10:00:00.000000Z],
          completed_at: ~U[2026-07-01 10:12:00.000000Z],
          output_lines: ["main run line one", "main run line two"]
        })

      {:ok, review} =
        Ash.create(Run, %{
          task_id: task.id <> "#review",
          repo: "test/repo",
          worker_type: :review,
          status: :failed,
          exit_code: 1,
          failure_reason: "compile error in loop_queue.ex",
          started_at: ~U[2026-07-01 11:00:00.000000Z],
          completed_at: ~U[2026-07-01 11:06:00.000000Z],
          output_lines: ["review run transcript line"]
        })

      {:ok, task: task, main: main, review: review}
    end

    test "lists every run for the issue with role filter tabs and counts",
         %{conn: conn, task: task} do
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "RUNS"
      assert html =~ "2 total"
      # One tab per role present, plus All.
      assert html =~ "All 2"
      assert html =~ "main 1"
      assert html =~ "review 1"
    end

    test "an interrupted run shows its reason but is not styled as a failure (bd-aje6fj)",
         %{conn: conn, task: task} do
      # The agent took systemd's SIGTERM with the BEAM, so it exited 143 — but
      # the run was shut down with the server, not failed.
      {:ok, interrupted} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :main,
          status: :interrupted,
          exit_code: 143,
          failure_reason: "server shutdown",
          started_at: ~U[2026-07-01 12:00:00.000000Z],
          completed_at: ~U[2026-07-01 12:03:00.000000Z]
        })

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "server shutdown"

      view |> element(~s([phx-value-run="#{interrupted.id}"])) |> render_click()
      refute has_element?(view, ~s(span[class*="arb-fail-text"]), "server shutdown")
    end

    test "a run row expands in place to its transcript — no navigation",
         %{conn: conn, task: task, main: main} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "main run line one"

      html = view |> element(~s([phx-value-run="#{main.id}"])) |> render_click()

      assert html =~ "main run line one"
      assert html =~ "main run line two"
      # Still on the task detail page — nothing navigated away.
      assert html =~ "Board / Issues /"

      # Clicking the open row collapses it.
      html = view |> element(~s([phx-value-run="#{main.id}"])) |> render_click()
      refute html =~ "main run line one"
    end

    test "the expanded transcript header carries the run's machine facts",
         %{conn: conn, task: task, review: review} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element(~s([phx-value-run="#{review.id}"])) |> render_click()

      assert html =~ "exit 1 · compile error in loop_queue.ex"
      assert html =~ "1 lines" or html =~ "1 line"
      assert html =~ "Open session"
      assert html =~ "Full transcript"
    end

    test "a running run's transcript streams from the live worker, not output_lines",
         %{conn: conn, task: task} do
      # This is the exact shape `worker.ex` persists at run start: the column
      # is written once as `[]` and not touched again until the run finishes.
      {:ok, running} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :main,
          status: :running,
          started_at: ~U[2026-07-02 09:00:00.000000Z],
          output_lines: []
        })

      start_supervised!(%{
        id: :fake_worker,
        start: {FakeWorker, :start_link, [task.id, ["seeded line from the snapshot"]]}
      })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element(~s([phx-value-run="#{running.id}"])) |> render_click()

      # Seeded from the worker snapshot rather than the empty persisted column.
      assert html =~ "seeded line from the snapshot"
      refute html =~ "No output captured for this run."

      # ... and subsequent output lands without a reload.
      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "worker:" <> task.id,
        {:worker_output, task.id, "a line broadcast mid-run"}
      )

      html = render(view)
      assert html =~ "a line broadcast mid-run"
      assert html =~ "2 lines"
    end

    test "an ended run's Open session link is disabled even while a worker is alive",
         %{conn: conn, task: task, main: main} do
      # A worker is running for this issue right now — but `main` completed
      # yesterday, so its own session is gone and the link must not offer it.
      start_supervised!(%{
        id: :fake_worker,
        start: {FakeWorker, :start_link, [task.id, []]}
      })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element(~s([phx-value-run="#{main.id}"])) |> render_click()

      # The two branches are mutually exclusive, so the disabled span being
      # rendered is exactly the assertion that the live link was not.
      assert html =~ "This run has ended — its live session is gone"
    end

    test "role tabs filter the roster by worker_type", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element(~s([phx-value-tab="review"])) |> render_click()

      assert html =~ "review"
      refute html =~ "fix pass"
    end

    test "a role with no runs shows the roster empty state", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "runless", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "No runs of this kind on this issue yet."
    end

    # The roster covers the review gate's `#review` runs as well as the
    # issue's own, so it has to go live for both. A review worker broadcasts
    # its lifecycle under `<id>#review`; matching only the bare id leaves the
    # review half of the roster stale until a full page reload.
    test "a review-gate run's lifecycle event refreshes the roster",
         %{conn: conn, task: task} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "later review run"

      {:ok, _} =
        Ash.create(Run, %{
          task_id: task.id <> "#review",
          repo: "test/repo",
          worker_type: :review,
          status: :running,
          started_at: ~U[2026-07-01 12:00:00.000000Z],
          output_lines: ["later review run"]
        })

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "workers",
        {:worker_lifecycle, :started, %{task_id: task.id <> "#review"}}
      )

      html = render(view)

      assert html =~ "3 total"
      assert html =~ "review 2"
    end

    # A revise round and a merge-queue fix pass run under deeper synthetic ids
    # (`<id>#review#impl2`, `<id>#fix`), which is exactly what the run's own
    # `base_task_id` column records. Scoping the roster to `[id, id#review]`
    # alone leaves the `impl` and `fix pass` tabs permanently empty.
    test "the roster covers revise-round and fix-pass runs by base_task_id",
         %{conn: conn, task: task} do
      {:ok, _} =
        Ash.create(Run, %{
          task_id: task.id <> "#review#impl2",
          base_task_id: task.id,
          repo: "test/repo",
          worker_type: :impl,
          status: :completed,
          started_at: ~U[2026-07-01 11:30:00.000000Z],
          completed_at: ~U[2026-07-01 11:40:00.000000Z],
          output_lines: ["revise round transcript"]
        })

      {:ok, _} =
        Ash.create(Run, %{
          task_id: task.id <> "#fix",
          base_task_id: task.id,
          repo: "test/repo",
          worker_type: :fix_pass,
          status: :completed,
          started_at: ~U[2026-07-01 12:30:00.000000Z],
          completed_at: ~U[2026-07-01 12:35:00.000000Z],
          output_lines: ["fix pass transcript"]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "4 total"
      assert html =~ "impl 1"
      assert html =~ "fix pass 1"
    end
  end

  describe "activity stream (the audit log folds in)" do
    test "renders this issue's audit transitions and links to the audit page",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "audited", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{priority: 0})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "ACTIVITY"
      assert html =~ "create"
      assert html =~ "update"
      # Same transitions the /audit page shows, scoped to this subject.
      assert html =~ "/audit?entity_id=#{task.id}"
      # README §4 asks for relative time in the gutter, not an absolute stamp.
      assert html =~ ~r/\d+[smhd] ago/
      assert html =~ "2 transitions"
    end

    test "the panel meta says so when the stream is truncated", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "chatty", workspace_id: ws.id})

      # 1 create + 24 updates = 25 versions, past the 20-row query cap.
      Enum.reduce(1..24, task, fn n, acc ->
        {:ok, updated} = Ash.update(acc, %{title: "chatty #{n}"})
        updated
      end)

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "latest 20 of 25 transitions"
    end
  end

  describe "right rail" do
    test "the current run block summarises the issue's runs rather than naming one worker",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "railed", workspace_id: ws.id})

      for started <- [~U[2026-07-01 10:00:00.000000Z], ~U[2026-07-01 11:00:00.000000Z]] do
        {:ok, _} =
          Ash.create(Run, %{
            task_id: task.id,
            repo: "test/repo",
            status: :completed,
            started_at: started
          })
      end

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "CURRENT RUN"
      assert html =~ "2 runs on this issue"
    end

    test "machine state, relationships and skills each render in the rail",
         %{conn: conn, ws: ws} do
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})

      {:ok, task} =
        Ash.create(Issue, %{
          title: "railed",
          workspace_id: ws.id,
          target_branch: "main"
        })

      {:ok, task} = Ash.update(task, %{pr_ref: "#591"})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: task.id,
          to_issue_id: blocker.id,
          type: :blocks
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "MACHINE STATE"
      assert html =~ "#591"

      assert html =~ "RELATIONSHIPS"
      assert html =~ "blocks"
      assert html =~ blocker.id

      assert html =~ "SKILLS"
    end

    # bd-a39f4o: Messages is a placeholder panel on this ticket — ticket C
    # fills it with real `Arbiter.Messages.Message` data.
    test "the messages panel renders an empty state placeholder", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "messageless", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      messages_panel = view |> element("#panel-messages") |> render()
      assert messages_panel =~ "MESSAGES"
    end

    # bd-a39f4o: status/priority/type/difficulty are already in the header
    # band, so Machine State must not repeat them (design finding #1).
    test "machine state no longer repeats the header's status/priority/type/difficulty chips",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "trimmed",
          workspace_id: ws.id,
          priority: 1,
          issue_type: :bug
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      machine_state = view |> element("#panel-machine-state") |> render()

      refute machine_state =~ "Status"
      refute machine_state =~ "Priority"
      refute machine_state =~ "Difficulty"
      refute machine_state =~ ">Type<"
    end

    # bd-a39f4o: parent/child progress moves out of Machine State and into
    # Relationships, alongside the dependency edges (design finding #4).
    test "relationships panel shows child progress instead of machine state",
         %{conn: conn, ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})
      {:ok, _} = Ash.update(child, %{}, action: :close)

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")

      relationships = view |> element("#panel-relationships") |> render()
      assert relationships =~ "1/1 closed"

      machine_state = view |> element("#panel-machine-state") |> render()
      refute machine_state =~ "Children"
    end

    test "machine state names the repo the issue runs against", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "checked out", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "acme/widgets",
          status: :completed,
          started_at: ~U[2026-07-01 10:00:00.000000Z]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "MACHINE STATE"
      assert html =~ "acme/widgets"
    end

    test "the skills rail lists the effective set a dispatch would carry", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "skill-ws-#{System.unique_integer([:positive])}",
          prefix: "sk",
          config: %{"skills" => %{"workspace" => ["rail-tdd"]}}
        })

      {:ok, _skill} =
        Arbiter.Skills.create_skill(%{
          name: "rail-tdd",
          body: "# TDD",
          activation_mode: :always_on
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "skilled", workspace_id: ws.id, issue_type: :feature})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "rail-tdd"
      assert html =~ "always_on"
    end
  end

  # bd-11r7e1: R1 regroups RELATIONSHIPS by semantic role (blocked_by,
  # blocks, parents, children, relates_to, conflicts_with, discovered_from)
  # rather than by raw edge direction.
  describe "RELATIONSHIPS panel regrouping (bd-11r7e1)" do
    test "parent_of edges land under Parent/Children, never under a blocking heading",
         %{conn: conn, ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent epic", workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "child issue", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      parent_html = view |> element("#panel-relationships") |> render()

      assert has_element?(view, "#rel-children")
      refute has_element?(view, "#rel-blocked-by")
      refute has_element?(view, "#rel-blocks")
      assert parent_html =~ child.id

      {:ok, view, _html} = live(conn, ~p"/tasks/#{child.id}")
      child_html = view |> element("#panel-relationships") |> render()

      assert has_element?(view, "#rel-parents")
      refute has_element?(view, "#rel-blocked-by")
      refute has_element?(view, "#rel-blocks")
      assert child_html =~ parent.id
    end

    test "empty groups are omitted entirely", %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :relates_to})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{a.id}")

      assert has_element?(view, "#rel-related")
      refute has_element?(view, "#rel-blocked-by")
      refute has_element?(view, "#rel-blocks")
      refute has_element?(view, "#rel-parents")
      refute has_element?(view, "#rel-children")
      refute has_element?(view, "#rel-conflicts-with")
      refute has_element?(view, "#rel-discovered-from")
    end

    test "each of the seven groups renders by its own element id when populated",
         %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})
      {:ok, c} = Ash.create(Issue, %{title: "C", workspace_id: ws.id})
      {:ok, d} = Ash.create(Issue, %{title: "D", workspace_id: ws.id})
      {:ok, e} = Ash.create(Issue, %{title: "E", workspace_id: ws.id})
      {:ok, f} = Ash.create(Issue, %{title: "F", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :depends_on})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: c.id, to_issue_id: a.id, type: :depends_on})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: d.id, to_issue_id: a.id, type: :parent_of})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: e.id, type: :relates_to})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: f.id, type: :conflicts_with})

      {:ok, g} = Ash.create(Issue, %{title: "G", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: g.id, type: :discovered_from})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{a.id}")

      assert has_element?(view, "#rel-blocked-by")
      assert has_element?(view, "#rel-blocks")
      assert has_element?(view, "#rel-parents")
      assert has_element?(view, "#rel-related")
      assert has_element?(view, "#rel-conflicts-with")
      assert has_element?(view, "#rel-discovered-from")
    end

    test "gating groups carry a data-gating marker that informational groups don't",
         %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})
      {:ok, c} = Ash.create(Issue, %{title: "C", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :depends_on})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: c.id, type: :relates_to})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{a.id}")

      assert has_element?(view, "#rel-blocked-by[data-gating=true]")
      assert has_element?(view, "#rel-related[data-gating=false]")
    end

    test "children group shows a progress bar and an auto_close marker when set",
         %{conn: conn, ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", workspace_id: ws.id, auto_close: true})

      {:ok, closed_child} = Ash.create(Issue, %{title: "done child", workspace_id: ws.id})
      {:ok, _} = Ash.update(closed_child, %{}, action: :close)
      {:ok, open_child} = Ash.create(Issue, %{title: "open child", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: closed_child.id,
          type: :parent_of
        })

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: open_child.id,
          type: :parent_of
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      children = view |> element("#rel-children") |> render()

      assert children =~ "1/2 closed"
      assert children =~ closed_child.id
      assert children =~ open_child.id
      assert has_element?(view, "#rel-children [role=progressbar]")
      assert has_element?(view, "#rel-children [data-role=auto-close-marker]")
    end

    test "an awaiting_verification blocker gets a distinct chip, explanation, and verify hint",
         %{conn: conn, ws: ws} do
      {:ok, blocker} =
        Ash.create(Issue, %{title: "merged blocker", workspace_id: ws.id})

      {:ok, blocker} = Ash.update(blocker, %{}, action: :await_verification)

      {:ok, downstream} = Ash.create(Issue, %{title: "waiting", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: downstream.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{downstream.id}")
      blocked_by = view |> element("#rel-blocked-by") |> render()

      assert has_element?(view, "#rel-blocked-by [data-role=awaiting-verification-chip]")
      assert blocked_by =~ "awaiting verification"
      assert blocked_by =~ "waiting on someone to verify"
      assert blocked_by =~ "arb issue verify #{blocker.id}"
    end

    test "edge notes and created_by are reachable from the row when present",
         %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :depends_on,
          notes: "waiting on the migration to land first",
          created_by: "dashboard"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{a.id}")

      assert html =~ "waiting on the migration to land first"
      assert html =~ "dashboard"
    end

    test "a cross-workspace edge renders with a marker", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "other-ws-#{System.unique_integer([:positive])}",
          prefix: "othr"
        })

      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: other_ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :relates_to})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{a.id}")

      assert has_element?(view, "#rel-related [data-role=cross-workspace-marker]")
    end
  end

  describe "handoff §4 detail" do
    test "the title block dates the issue in relative time", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "dated", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # `opened 2d ago · updated 41m ago` — the operator reads age, not
      # wall-clock stamps, in the header.
      assert html =~ "opened "
      assert html =~ "updated "
      assert html =~ ~r/opened \d+[smhd] ago/
      assert html =~ ~r/updated \d+[smhd] ago/
    end

    test "acceptance criteria use the handoff Checkbox, not the daisyUI one",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "handoff checkbox",
          acceptance: "- [x] done one\n- [ ] pending two",
          workspace_id: ws.id
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # The handoff Checkbox hides the native input and draws its own 14px
      # box; the daisyUI one keeps the native control with `checkbox` classes.
      refute html =~ "checkbox checkbox-xs"
      assert html =~ "sr-only peer"
      # Checked boxes carry the tick glyph.
      assert html =~ "✓"
    end

    test "the runs header counts running rows and totals their spend",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "spendy", workspace_id: ws.id})

      {:ok, done} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :main,
          status: :completed,
          started_at: ~U[2026-07-01 10:00:00.000000Z],
          completed_at: ~U[2026-07-01 10:12:00.000000Z]
        })

      {:ok, _running} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :impl,
          status: :running,
          started_at: ~U[2026-07-01 11:00:00.000000Z]
        })

      {:ok, _usage} =
        Ash.create(Arbiter.Usage.Event, %{
          task_id: task.id,
          worker_run_id: done.id,
          step: :work,
          provider: "anthropic",
          model: "sonnet",
          cost_usd: 3.42,
          occurred_at: ~U[2026-07-01 10:12:00.000000Z]
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "2 total"
      assert html =~ "1 running"
      assert html =~ "$3.42"
    end

    test "role tabs follow the handoff order and label fix_pass as prose",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "roles", workspace_id: ws.id})

      for {role, task_id} <- [
            {:review, task.id <> "#review"},
            {:conflict, task.id},
            {:fix_pass, task.id},
            {:impl, task.id},
            {:main, task.id}
          ] do
        {:ok, _} =
          Ash.create(Run, %{
            task_id: task_id,
            repo: "test/repo",
            worker_type: role,
            status: :completed,
            started_at: ~U[2026-07-01 10:00:00.000000Z]
          })
      end

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "fix pass 1"
      refute html =~ "fix_pass 1"

      order = ~w(all main impl review fix_pass conflict)

      positions =
        Enum.map(order, fn value ->
          {pos, _} = :binary.match(html, ~s(phx-value-tab="#{value}"))
          pos
        end)

      assert positions == Enum.sort(positions),
             "filter tabs are out of handoff order: #{inspect(Enum.zip(order, positions))}"
    end
  end

  # bd-db3wxp: markdown-bearing fields render as sanitized HTML via the shared
  # `<.markdown>` component, not as raw text in a `<pre>`.
  describe "markdown rendering" do
    @md """
    # Heading

    Some **bold** text with a [link](https://example.com).

    - one
    - two

    A paragraph between the two lists, so neither goes loose.

    - [ ] unchecked
    - [x] checked

    | a | b |
    | --- | --- |
    | 1 | 2 |

    ```elixir
    IO.puts("hi")
    ```
    """

    @xss """
    <script>alert(1)</script>

    <img src=x onerror=alert(1)>

    [click](javascript:alert(1))
    """

    test "renders the description as formatted HTML", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "md-desc", description: @md, workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "<h1>Heading</h1>"
      assert html =~ "<strong>bold</strong>"
      assert html =~ ~s(href="https://example.com")
      assert html =~ "<li>one</li>"
      assert html =~ "<table>"
      assert html =~ ~s(type="checkbox")
      assert html =~ "<code"
      # The old raw-text <pre> treatment is gone.
      refute html =~ "# Heading"
    end

    test "renders notes as formatted HTML for a non-task issue", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "md-notes", issue_type: :feature, workspace_id: ws.id})

      {:ok, task} = Ash.update(task, %{notes: @md})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "<h1>Heading</h1>"
      refute html =~ "# Heading"
    end

    test "renders findings notes as formatted HTML for a task-type issue", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "md-findings", issue_type: :task, workspace_id: ws.id})

      {:ok, task} = Ash.update(task, %{notes: @md})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "<h1>Heading</h1>"
    end

    test "renders pr_body, qa_notes and deployment_notes as formatted HTML",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "md-pr", workspace_id: ws.id})

      {:ok, task} =
        Ash.update(task, %{
          pr_body: "## PR heading\n\n- bullet\n",
          qa_notes: "## QA heading\n\n- qa bullet\n",
          deployment_notes: "## Deploy heading\n\n- deploy bullet\n"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "<h2>PR heading</h2>"
      assert html =~ "<h2>QA heading</h2>"
      assert html =~ "<h2>Deploy heading</h2>"
      assert html =~ "<li>bullet</li>"
      refute html =~ "## PR heading"
    end

    test "strips XSS payloads from every markdown surface", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "md-xss", description: @xss, workspace_id: ws.id})

      {:ok, task} =
        Ash.update(task, %{
          notes: @xss,
          pr_body: @xss,
          qa_notes: @xss,
          deployment_notes: @xss
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Scoped to the markdown containers: the page's own root layout legitimately
      # carries <script src="/assets/js/app.js"> tags, which a whole-page refute
      # would trip over.
      for id <- ~w(task-description-md task-notes-md task-pr-body-md
                   task-qa-notes-md task-deployment-notes-md) do
        assert has_element?(view, "##{id}"), "expected a markdown container ##{id}"
        rendered = view |> element("##{id}") |> render()

        refute rendered =~ "<script"
        refute rendered =~ "onerror="
        refute rendered =~ "javascript:"
      end
    end

    test "leaves acceptance criteria as the existing checklist renderer",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "md-acceptance",
          acceptance: "- [ ] first criterion\n- [x] second criterion\n",
          workspace_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#criterion-0")
      assert has_element?(view, "#criterion-1")
    end
  end

  describe "review-round summary in MERGE & REVIEW (bd-9mqima)" do
    # The summary is sourced from `Arbiter.ReviewGate.Round` — the authoritative
    # record of what each reviewer pass actually decided — not from the runs'
    # exit status, which cannot tell an approval from a rejection.
    setup %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "reviewed", workspace_id: ws.id, target_branch: "main"})

      {:ok, task: task}
    end

    defp review_run(task, round) do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: task.id <> "#review",
          repo: "test/repo",
          worker_type: :review,
          status: :completed,
          started_at: DateTime.add(~U[2026-07-01 10:00:00.000000Z], round, :hour),
          completed_at: DateTime.add(~U[2026-07-01 10:30:00.000000Z], round, :hour),
          output_lines: ["round #{round} reviewer transcript"]
        })

      run
    end

    defp round!(task, attrs) do
      {:ok, round} =
        Ash.create(
          Round,
          Map.merge(%{task_id: task.id, role: :review, converged: false}, Map.new(attrs))
        )

      round
    end

    test "renders round count and the latest round's verdict", %{conn: conn, task: task} do
      r1 = review_run(task, 1)
      r2 = review_run(task, 2)

      round!(task, %{round: 1, run_id: r1.id, verdict: :request_changes, finding_count: 3})
      round!(task, %{round: 1, role: :impl, verdict: nil, findings: "fixed them"})
      round!(task, %{round: 2, run_id: r2.id, verdict: :approve, converged: true})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-round-summary")
      summary = view |> element("#review-round-summary") |> render()

      assert summary =~ "2 rounds"
      assert summary =~ "round 2"
      assert summary =~ "approved"
    end

    test "a single request_changes round reads honestly, not as an approval",
         %{conn: conn, task: task} do
      r1 = review_run(task, 1)
      round!(task, %{round: 1, run_id: r1.id, verdict: :request_changes, finding_count: 2})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      summary = view |> element("#review-round-summary") |> render()

      assert summary =~ "1 round"
      assert summary =~ "changes requested"
      refute summary =~ "approved"
    end

    test "a timed-out round is never shown as approved", %{conn: conn, task: task} do
      # The reviewing pass exhausted its budget with no verdict. Its own run row
      # can still be `:completed` — only the round record knows it timed out.
      r1 = review_run(task, 1)
      round!(task, %{round: 1, run_id: r1.id, verdict: :timed_out, finding_count: 0})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      summary = view |> element("#review-round-summary") |> render()

      assert summary =~ "timed out"
      refute summary =~ "approved"
      refute summary =~ "changes requested"
    end

    test "a review round with no verdict reads as inconclusive", %{conn: conn, task: task} do
      r1 = review_run(task, 1)
      round!(task, %{round: 1, run_id: r1.id, verdict: nil, findings: "no parseable VERDICT"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      summary = view |> element("#review-round-summary") |> render()

      assert summary =~ "inconclusive"
      refute summary =~ "approved"
    end

    test "the verdict comes from the round record, not the run's exit status",
         %{conn: conn, task: task} do
      # A reviewer run that exited 0 and completed cleanly, whose verdict was
      # REQUEST_CHANGES. Reading the run alone would call this a pass.
      r1 = review_run(task, 1)
      assert r1.status == :completed
      round!(task, %{round: 1, run_id: r1.id, verdict: :request_changes, finding_count: 1})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      summary = view |> element("#review-round-summary") |> render()

      assert summary =~ "changes requested"
      refute summary =~ "approved"
    end

    test "clicking the summary expands the matching run row in RUNS",
         %{conn: conn, task: task} do
      r1 = review_run(task, 1)
      r2 = review_run(task, 2)

      round!(task, %{round: 1, run_id: r1.id, verdict: :request_changes, finding_count: 3})
      round!(task, %{round: 2, run_id: r2.id, verdict: :approve, converged: true})

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      refute html =~ "round 2 reviewer transcript"

      html = view |> element("#review-round-summary") |> render_click()

      # The latest round's own run row, expanded in place — no navigation.
      assert html =~ "round 2 reviewer transcript"
      refute html =~ "round 1 reviewer transcript"
      assert html =~ "Board / Issues /"
    end

    test "the deep link clears a role filter that would be hiding the row",
         %{conn: conn, task: task} do
      r1 = review_run(task, 1)
      round!(task, %{round: 1, run_id: r1.id, verdict: :approve, converged: true})

      {:ok, _main} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          worker_type: :main,
          status: :completed,
          started_at: ~U[2026-07-01 09:00:00.000000Z],
          completed_at: ~U[2026-07-01 09:30:00.000000Z],
          output_lines: ["main transcript"]
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Filter the roster to `main` — the reviewer row is no longer rendered.
      html = view |> element(~s([phx-value-tab="main"])) |> render_click()
      refute html =~ "round 1 reviewer transcript"

      html = view |> element("#review-round-summary") |> render_click()
      assert html =~ "round 1 reviewer transcript"
    end

    test "the panel appears on review activity alone, with no PR or target branch",
         %{conn: conn, ws: ws} do
      {:ok, bare} = Ash.create(Issue, %{title: "no pr yet", workspace_id: ws.id})
      round!(bare, %{round: 1, verdict: :approve, converged: true})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{bare.id}")

      assert has_element?(view, "#panel-merge-review")
      summary = view |> element("#review-round-summary") |> render()
      assert summary =~ "approved"
      # No run on the roster to link to — the line renders, inert.
      assert summary =~ "disabled"
    end

    test "no summary renders for a task with no review activity", %{conn: conn, task: task} do
      _ = review_run(task, 1)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#review-round-summary")
    end
  end

  defp panel_position(html, id) do
    :binary.match(html, ~s(id="#{id}")) |> elem(0)
  end

  describe "MESSAGES panel" do
    test "renders messages addressed to or about the task, newest first, and nothing else", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "messaged", workspace_id: ws.id})
      {:ok, other} = Ash.create(Issue, %{title: "unrelated", workspace_id: ws.id})

      {:ok, addressed} =
        Message.send_mail(%{
          kind: :direction,
          workspace_id: ws.id,
          from_ref: "coordinator",
          to_ref: task.id,
          subject: "conflict instructions",
          body: "rebase **onto main**"
        })

      {:ok, about} =
        Message.send_mail(%{
          kind: :escalation,
          workspace_id: ws.id,
          from_ref: task.id,
          to_ref: "coordinator",
          task_ref: task.id,
          subject: "review rejected",
          body: "needs a decision"
        })

      {:ok, unrelated} =
        Message.send_mail(%{
          kind: :info,
          workspace_id: ws.id,
          from_ref: other.id,
          to_ref: "coordinator",
          task_ref: other.id,
          subject: "not this one",
          body: "unrelated"
        })

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#panel-messages")
      assert has_element?(view, "#message-#{addressed.id}")
      assert has_element?(view, "#message-#{about.id}")
      refute has_element?(view, "#message-#{unrelated.id}")

      # newest first
      assert :binary.match(html, "message-#{about.id}") <
               :binary.match(html, "message-#{addressed.id}")

      # kind, from/to, subject and a relative time all render
      assert has_element?(view, "#message-#{about.id} [data-kind='escalation']")
      assert has_element?(view, "#message-#{addressed.id} [data-kind='direction']")
      assert has_element?(view, "#message-#{addressed.id} [data-role='message-parties']")
      assert has_element?(view, "#message-#{addressed.id} [data-role='message-time']")
      assert has_element?(view, "#message-#{addressed.id} [data-role='message-subject']")

      # body goes through the sanitized markdown component
      assert has_element?(view, "#message-body-md-#{addressed.id} strong")
    end

    test "viewing the page does not mark a message read or cleared", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "read state", workspace_id: ws.id})

      {:ok, msg} =
        Message.send_mail(%{
          kind: :direction,
          workspace_id: ws.id,
          from_ref: "coordinator",
          to_ref: task.id,
          subject: "do the thing",
          body: "please"
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#message-#{msg.id}")

      {:ok, reloaded} = Ash.get(Message, msg.id)
      assert reloaded.read_at == nil
      assert reloaded.cleared_at == nil
    end

    test "a new message for the task appears live", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "live messages", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "[data-role='message-row']")

      {:ok, msg} =
        Message.send_mail(%{
          kind: :flag,
          workspace_id: ws.id,
          from_ref: "bd-sibling",
          to_ref: task.id,
          subject: "api shape changed",
          body: "heads up"
        })

      assert render(view) =~ "message-#{msg.id}"
      assert has_element?(view, "#message-#{msg.id}")
    end

    test "a long body is collapsed until the disclosure is clicked", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "long message", workspace_id: ws.id})

      {:ok, msg} =
        Message.send_mail(%{
          kind: :escalation,
          workspace_id: ws.id,
          from_ref: task.id,
          to_ref: "coordinator",
          task_ref: task.id,
          subject: "findings",
          body: Enum.map_join(1..20, "\n", &"- finding #{&1}")
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#message-toggle-#{msg.id}", "show more")

      view |> element("#message-toggle-#{msg.id}") |> render_click()
      assert has_element?(view, "#message-toggle-#{msg.id}", "show less")

      # expanding is a disclosure, not a read acknowledgement
      {:ok, reloaded} = Ash.get(Message, msg.id)
      assert reloaded.read_at == nil
      assert reloaded.cleared_at == nil
    end

    test "renders an empty state when the task has no messages", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no messages", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#panel-messages")
      refute has_element?(view, "[data-role='message-row']")
      assert has_element?(view, "#messages-empty")
    end
  end

  # bd-1273p2: design bd-2s901b §3 — an epic's children grouped into the
  # board's own five columns, below RELATIONSHIPS' flat Children rollup.
  describe "epic children by status mini-board" do
    defp link_parent_of(epic, child) do
      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: epic.id, to_issue_id: child.id, type: :parent_of})

      :ok
    end

    test "groups children into Backlog/Ready/Running/Waiting/Closed like the board", %{
      conn: conn,
      ws: ws
    } do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, backlog_child} =
        Ash.create(Issue, %{title: "backlog child", workspace_id: ws.id})

      {:ok, ready_child} =
        Ash.create(Issue, %{title: "ready child", workspace_id: ws.id, acceptance: "- works"})

      {:ok, ready_child} = Ash.update(ready_child, %{}, action: :promote_to_ready)

      {:ok, running_child} =
        Ash.create(Issue, %{title: "running child", workspace_id: ws.id})

      {:ok, _pid} = Worker.start(task_id: running_child.id, repo: "r", workspace_id: ws.id)

      {:ok, waiting_child} = Ash.create(Issue, %{title: "waiting child", workspace_id: ws.id})
      {:ok, waiting_child} = Ash.update(waiting_child, %{}, action: :await_verification)

      {:ok, closed_child} = Ash.create(Issue, %{title: "closed child", workspace_id: ws.id})
      {:ok, closed_child} = Ash.update(closed_child, %{}, action: :close)

      for child <- [backlog_child, ready_child, running_child, waiting_child, closed_child] do
        link_parent_of(epic, child)
      end

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#panel-children-by-status")
      assert has_element?(view, "#children-backlog-#{backlog_child.id}", "backlog child")
      assert has_element?(view, "#children-ready-#{ready_child.id}", "ready child")
      assert has_element?(view, "#children-running-#{running_child.id}", "running child")
      assert has_element?(view, "#children-waiting-#{waiting_child.id}", "waiting child")
      assert has_element?(view, "#children-closed-#{closed_child.id}", "closed child")

      # A deliberately-unpromoted Backlog child carries no per-child stuck flag.
      refute has_element?(view, "#children-backlog-#{backlog_child.id} [data-role]")
    end

    test "a child depending on a sibling shows a marker naming it", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, blocker} =
        Ash.create(Issue, %{title: "blocker sibling", workspace_id: ws.id, acceptance: "- works"})

      {:ok, blocker} = Ash.update(blocker, %{}, action: :promote_to_ready)

      {:ok, blocked} =
        Ash.create(Issue, %{title: "blocked sibling", workspace_id: ws.id, acceptance: "- works"})

      {:ok, blocked} = Ash.update(blocked, %{}, action: :promote_to_ready)

      link_parent_of(epic, blocker)
      link_parent_of(epic, blocked)

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(
               view,
               "#children-ready-#{blocked.id} [data-role='sibling-depends-on-marker']",
               blocker.id
             )

      # A closed sibling is satisfied ordering history, not a live
      # constraint — its marker is dropped (design bd-2s901b §3).
      {:ok, _} = Ash.update(blocker, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      refute has_element?(
               view,
               "#children-ready-#{blocked.id} [data-role='sibling-depends-on-marker']"
             )
    end

    test "Closed collapses by default past 5 children", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      for n <- 1..6 do
        {:ok, child} = Ash.create(Issue, %{title: "closed #{n}", workspace_id: ws.id})
        {:ok, child} = Ash.update(child, %{}, action: :close)
        link_parent_of(epic, child)
      end

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      refute has_element?(view, "#children-closed details[open]")
    end

    test "Closed does not collapse with 5 or fewer children", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      for n <- 1..5 do
        {:ok, child} = Ash.create(Issue, %{title: "closed #{n}", workspace_id: ws.id})
        {:ok, child} = Ash.update(child, %{}, action: :close)
        link_parent_of(epic, child)
      end

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#children-closed details[open]")
    end

    test "a non-epic issue does not render the mini-board", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "plain task", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#panel-children-by-status")
    end

    test "a child's status change moves it between groups live", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} =
        Ash.create(Issue, %{title: "moving child", workspace_id: ws.id, acceptance: "- works"})

      {:ok, child} = Ash.update(child, %{}, action: :promote_to_ready)

      link_parent_of(epic, child)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#children-ready-#{child.id}")
      refute has_element?(view, "#children-closed-#{child.id}")

      {:ok, _} = Ash.update(child, %{}, action: :close)

      assert has_element?(view, "#children-closed-#{child.id}")
      refute has_element?(view, "#children-ready-#{child.id}")
    end

    test "a child's worker-only status transition moves it from Running to Waiting live", %{
      conn: conn,
      ws: ws
    } do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "reviewed child", workspace_id: ws.id})
      link_parent_of(epic, child)

      {:ok, pid} = Worker.start(task_id: child.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(pid, :implement)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#children-running-#{child.id}")

      # `Worker.await/2` is a worker-only transition (:running -> :awaiting):
      # it never writes the child's Issue row, so no `:task_lifecycle` fires —
      # only the "workers" PubSub topic does. This isolates the mini-board's
      # `epic_child?` refresh path (task_detail_live.ex) from the pre-existing
      # `:task_lifecycle` catch-all, which would repaint the board anyway and
      # mask a regression in the worker-only path.
      :ok = Worker.await(pid, :manual_pause)

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "workers",
        {:worker_lifecycle, :updated, %{task_id: child.id}}
      )

      assert has_element?(view, "#children-waiting-#{child.id}")
      refute has_element?(view, "#children-running-#{child.id}")
    end
  end

  # bd-18vl9q, design bd-9jj5lf §4: "$X spent · ~$Y-Z to go" on the epic
  # detail page.
  describe "epic cost rollup" do
    test "shows spent, to-go, and the breakdown counts", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, closed_child} = Ash.create(Issue, %{title: "closed child", workspace_id: ws.id})
      {:ok, closed_child} = Ash.update(closed_child, %{}, action: :close)
      link_parent_of(epic, closed_child)

      {:ok, _ev} =
        Ash.create(Arbiter.Usage.Event, %{
          task_id: closed_child.id,
          base_task_id: closed_child.id,
          role: "base",
          source: :task,
          step: :work,
          workspace_id: ws.id,
          cost_usd: 6.5,
          occurred_at: DateTime.utc_now()
        })

      {:ok, backlog_child} = Ash.create(Issue, %{title: "backlog child", workspace_id: ws.id})
      link_parent_of(epic, backlog_child)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#panel-epic-cost-rollup")
      assert has_element?(view, "#epic-cost-rollup-headline", "$6.50 spent")
      assert has_element?(view, "#epic-cost-rollup-breakdown", "1 closed")
      assert has_element?(view, "#epic-cost-rollup-breakdown", "1 upcoming")
    end

    test "shows blocked, in-flight, and sub-epic children — none as excluded", %{
      conn: conn,
      ws: ws
    } do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})

      {:ok, blocked} =
        Ash.create(Issue, %{title: "blocked child", workspace_id: ws.id, acceptance: "- works"})

      {:ok, blocked} = Ash.update(blocked, %{}, action: :promote_to_ready)
      link_parent_of(epic, blocked)

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, running_child} =
        Ash.create(Issue, %{
          title: "running child",
          workspace_id: ws.id,
          acceptance: "- works"
        })

      {:ok, running_child} = Ash.update(running_child, %{}, action: :promote_to_ready)
      {:ok, running_child} = Ash.update(running_child, %{status: :in_progress})
      link_parent_of(epic, running_child)

      {:ok, sub_epic} =
        Ash.create(Issue, %{title: "sub-epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, sub_epic} = Ash.update(sub_epic, %{}, action: :promote_to_ready)
      link_parent_of(epic, sub_epic)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#epic-cost-rollup-breakdown", "1 blocked")
      assert has_element?(view, "#epic-cost-rollup-breakdown", "1 in flight")
      assert has_element?(view, "#epic-cost-rollup-breakdown", "1 sub-epic")
      refute has_element?(view, "#epic-cost-rollup-breakdown", "excluded")
    end

    test "a non-epic issue does not render the cost rollup panel", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "plain task", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#panel-epic-cost-rollup")
    end

    test "a childless epic still renders the panel at all zeroes", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "childless epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

      assert has_element?(view, "#panel-epic-cost-rollup")
      assert has_element?(view, "#epic-cost-rollup-headline", "$0.00 spent")
    end
  end

  describe "the refinement session panel (bd-cvfjms)" do
    alias Arbiter.Sessions
    alias Arbiter.Test.NoopRunner
    alias Arbiter.Usage.Event

    setup do
      prev = Application.get_env(:arbiter, :output_log_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "task-detail-refine-session-test-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev do
          Application.put_env(:arbiter, :output_log_root, prev)
        else
          Application.delete_env(:arbiter, :output_log_root)
        end
      end)

      %{root: root}
    end

    defp seed_archive!(root, id) do
      File.mkdir_p!(root)
      File.write!(Path.join(root, id <> ".jsonl.gz"), :zlib.gzip(~s({"type":"assistant"}\n)))
    end

    test "an issue never refined shows no refinement session panel", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "never refined", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#panel-refine-session")
    end

    test "an ended, archived refine session shows its end reason, transcript link, and cost", %{
      conn: conn,
      ws: ws,
      root: root
    } do
      {:ok, task} = Ash.create(Issue, %{title: "was refined", workspace_id: ws.id})

      {:ok, session} =
        Sessions.launch(issue_id: task.id, workspace_id: ws.id, runner: NoopRunner)

      {:ok, session} = Sessions.record_provider_session(session, "prov-refine-1")

      {:ok, _ev} =
        Ash.create(Event, %{
          task_id: nil,
          source: :coordinator_session,
          step: :other,
          provider: "claude",
          model: "claude-opus-4-7",
          occurred_at: DateTime.utc_now(),
          session_id: "prov-refine-1",
          cost_usd: 3.25,
          tokens_in: 1000,
          tokens_out: 500
        })

      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "promoted")
      seed_archive!(root, session.id)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#panel-refine-session", "promoted")

      # The archived JSONL, not the raw PTY stream the dock replays
      # (bd-3tf4oo gave `/sessions/:id/transcript` to the raw capture).
      assert has_element?(
               view,
               ~s(#refine-session-transcript-link[href="/sessions/#{session.id}/jsonl"])
             )

      assert has_element?(view, "#refine-session-cost", "$3.25")
    end

    test "an ended but unarchived refine session shows no transcript link", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "was refined, not archived", workspace_id: ws.id})

      {:ok, session} =
        Sessions.launch(issue_id: task.id, workspace_id: ws.id, runner: NoopRunner)

      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "issue_closed")

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#panel-refine-session", "issue_closed")
      refute has_element?(view, "#refine-session-transcript-link")
    end
  end
end
