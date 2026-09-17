defmodule ArbiterWeb.RefineEntryPointTest do
  @moduledoc """
  bd-1lszsc acceptance 1 and 2: the **Refine** action on Backlog issues.

  Both entry points — the issue detail page and the board card — and the one
  thing they both do: launch or reopen the single refine session bound to the
  issue, and open it in the dock.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Sessions
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)

    Arbiter.Test.SessionEnv.sandbox("refine-entry")
    # A Refine click launches inside the LiveView process, which cannot see
    # the test's process dictionary, so the runner stub has to come from
    # application config or the click would really shell out to `systemd-run`.
    put_env(:sessions_runner, NoopRunner)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "refine-entry-ws-#{System.unique_integer([:positive])}",
        prefix: "ref"
      })

    {:ok, issue} = Ash.create(Issue, %{title: "shape me", workspace_id: ws.id})

    {:ok, ws: ws, issue: issue}
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  describe "the issue detail page" do
    test "offers Refine on a Backlog issue", %{conn: conn, issue: issue} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{issue.id}")
      assert has_element?(view, "#task-refine")
    end

    test "does not offer it on a refined issue", %{conn: conn, issue: issue} do
      {:ok, issue} = Ash.update(issue, %{acceptance: "- ac"}, action: :update)
      {:ok, refined} = Ash.update(issue, %{}, action: :promote_to_ready)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{refined.id}")
      refute has_element?(view, "#task-refine")
    end

    test "does not offer it on a running issue", %{conn: conn, issue: issue} do
      {:ok, running} = Ash.update(issue, %{status: :in_progress}, action: :update)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{running.id}")
      refute has_element?(view, "#task-refine")
    end

    test "does not offer it on a closed issue", %{conn: conn, issue: issue} do
      {:ok, closed} = Ash.update(issue, %{reason: "dropped"}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{closed.id}")
      refute has_element?(view, "#task-refine")
    end

    test "a click launches the bound session and opens it in the dock", %{
      conn: conn,
      issue: issue
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{issue.id}")
      dock = find_live_child(view, "session-dock")

      render_click(element(view, "#task-refine"))

      assert [session] = Sessions.list()
      assert session.issue_id == issue.id
      assert session.name == "Refine #{issue.id}: shape me"

      assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))
    end

    test "a second click reopens the same session, never a second one", %{
      conn: conn,
      issue: issue
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{issue.id}")

      render_click(element(view, "#task-refine"))
      assert [first] = Sessions.list()

      render_click(element(view, "#task-refine"))
      assert [second] = Sessions.list()
      assert second.id == first.id
    end
  end

  describe "the board card" do
    test "offers Refine on Backlog cards", %{conn: conn, issue: issue} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#board-refine-#{issue.id}")
    end

    test "does not offer it on a Ready card", %{conn: conn, issue: issue} do
      {:ok, issue} = Ash.update(issue, %{acceptance: "- ac"}, action: :update)
      {:ok, refined} = Ash.update(issue, %{}, action: :promote_to_ready)

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#board-refine-#{refined.id}")
    end

    test "a click launches the bound session and opens it in the dock", %{
      conn: conn,
      issue: issue
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      dock = find_live_child(view, "session-dock")

      render_click(element(view, "#board-refine-#{issue.id}"))

      assert [session] = Sessions.list()
      assert session.issue_id == issue.id
      assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))
    end
  end

  describe "the dock" do
    test "an open request from another view expands that session's window", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      dock = find_live_child(view, "session-dock")

      {:ok, session} = Sessions.launch(runner: NoopRunner)
      Sessions.request_open(session.id)

      assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))
    end

    test "an open request for a session that does not exist is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      dock = find_live_child(view, "session-dock")

      Sessions.request_open(Ash.UUID.generate())

      assert render(dock) =~ "session-dock-root"
    end
  end
end
