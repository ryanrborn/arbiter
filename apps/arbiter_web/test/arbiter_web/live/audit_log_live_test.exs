defmodule ArbiterWeb.AuditLogLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "audit-#{System.unique_integer([:positive])}", prefix: "au"})

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders the header, filter tabs, and search input when there are no events", %{
      conn: conn,
      ws: _ws
    } do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "Audit log"
      assert html =~ "All"
      assert html =~ "Human"
      assert html =~ "Machine"
      assert html =~ "subject:"
    end

    test "lists a create event for the subject/action columns", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "audit me", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ task.id
      assert html =~ "create"
    end
  end

  describe "status transitions" do
    test "renders the literal old → new status, never prettified", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "transition me", workspace_id: ws.id})

      {:ok, _task} =
        Ash.update(task, %{status: :in_progress, change_origin: "cli"}, action: :update)

      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "open → in_progress"
    end
  end

  describe "actor filter tabs" do
    test "Machine tab narrows to worker-attributed events", %{conn: conn, ws: ws} do
      {:ok, human_task} = Ash.create(Issue, %{title: "human edit", workspace_id: ws.id})
      {:ok, machine_task} = Ash.create(Issue, %{title: "machine edit", workspace_id: ws.id})

      {:ok, _} =
        Ash.update(human_task, %{status: :in_progress, change_origin: "cli"}, action: :update)

      {:ok, _} =
        Ash.update(machine_task, %{status: :in_progress, change_origin: "worker:au-1"},
          action: :update
        )

      {:ok, view, _html} = live(conn, "/audit")

      html = render_click(view, "filter-tab", %{"tab" => "machine"})

      assert html =~ "worker:au-1"
      refute html =~ ~r/>\s*cli\s*</
    end

    test "Human tab narrows to non-worker-attributed events", %{conn: conn, ws: ws} do
      {:ok, human_task} = Ash.create(Issue, %{title: "human edit", workspace_id: ws.id})
      {:ok, machine_task} = Ash.create(Issue, %{title: "machine edit", workspace_id: ws.id})

      {:ok, _} =
        Ash.update(human_task, %{status: :in_progress, change_origin: "cli"}, action: :update)

      {:ok, _} =
        Ash.update(machine_task, %{status: :in_progress, change_origin: "worker:au-1"},
          action: :update
        )

      {:ok, view, _html} = live(conn, "/audit")

      html = render_click(view, "filter-tab", %{"tab" => "human"})

      assert html =~ ~r/>\s*cli\s*</
      refute html =~ "worker:au-1"
    end
  end

  describe "query search" do
    test "subject: narrows to the matching task id", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "first", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "second", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/audit")

      html = render_change(view, "search", %{"q" => "subject:#{b1.id}"})

      assert html =~ b1.id
      refute html =~ b2.id
    end
  end

  describe "deep link from the task detail screen" do
    test "?entity_id= seeds the subject filter", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "linked", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "other", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/audit?entity_id=#{b1.id}")

      assert html =~ "value=\"subject:#{b1.id}\""
      assert html =~ b1.id
      refute html =~ b2.id
    end

    test "the subject filter survives a truncated 500-row read window", %{conn: conn, ws: ws} do
      {:ok, target} = Ash.create(Issue, %{title: "old history", workspace_id: ws.id})

      for n <- 1..500 do
        {:ok, filler} = Ash.create(Issue, %{title: "filler #{n}", workspace_id: ws.id})

        {:ok, _} =
          Ash.update(filler, %{status: :in_progress, change_origin: "cli"}, action: :update)
      end

      {:ok, _view, html} = live(conn, "/audit?entity_id=#{target.id}")

      assert html =~ target.id
    end
  end

  describe "mobile usability" do
    test "search input has responsive min-width for mobile viewports", %{conn: conn, ws: _ws} do
      {:ok, _view, html} = live(conn, "/audit")

      # Should have min-w-0 for mobile and sm:min-w-[240px] for larger screens
      # instead of fixed min-w-[240px] that pushes tabs to wrap on narrow viewports
      assert html =~ ~r/class="[^"]*min-w-0[^"]*sm:min-w-\[240px\][^"]*"/
    end

    test "subject column has defined width to prevent compression", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "width test", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/audit")

      # Subject column should have a width attribute to maintain legibility
      assert html =~ "width="
      assert html =~ task.id
    end
  end
end
