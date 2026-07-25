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
end
