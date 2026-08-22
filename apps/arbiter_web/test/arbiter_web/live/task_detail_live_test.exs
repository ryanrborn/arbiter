defmodule ArbiterWeb.TaskDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

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

    test "renders blocked-by + blocks dependency sections", %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{a.id}")

      assert html =~ "Blocked by (1)"
      assert html =~ b.id
      assert html =~ "B"
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
            "assignee" => "ada",
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
      assert reloaded.assignee == "ada"
      assert reloaded.target_branch == "release/x"
      assert reloaded.acceptance == "it works"
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

    test "machine state, dependencies and skills each render in the rail",
         %{conn: conn, ws: ws} do
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})

      {:ok, task} =
        Ash.create(Issue, %{
          title: "railed",
          workspace_id: ws.id,
          assignee: "ada",
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
      assert html =~ "ada"
      assert html =~ "#591"

      assert html =~ "DEPENDENCIES"
      assert html =~ "blocks"
      assert html =~ blocker.id

      assert html =~ "SKILLS"
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
end
