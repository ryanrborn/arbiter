defmodule ArbiterWeb.TaskDetailRelationshipsTest do
  @moduledoc """
  Ticket R3 (bd-dmabmg) — adding and removing relationships from the task
  detail page.

  The panel's read model is covered by `ArbiterWeb.TaskDetailLiveTest`; this
  file covers the write affordances: the sentence-phrased add modal, the
  scoped typeahead and its pre-checks, the four dispatch-impact warnings, the
  per-row remove, and the two-tab live refresh.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bd-ws-#{System.unique_integer([:positive])}", prefix: "bdt"})

    {:ok, ws: ws}
  end

  defp issue(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(
          %{title: "task #{System.unique_integer([:positive])}", workspace_id: ws.id},
          attrs
        )
      )

    issue
  end

  defp ready(issue) do
    {:ok, issue} = Ash.update(issue, %{}, action: :promote_to_ready)
    issue
  end

  defp edges do
    Dependency |> Ash.read!() |> Enum.map(&{&1.type, &1.from_issue_id, &1.to_issue_id})
  end

  # Drive the add modal end to end: open it, choose a phrase, search, select
  # the candidate, submit.
  defp add_relationship(view, phrase, target_id, opts \\ []) do
    view |> element("#rel-add-open") |> render_click()

    view
    |> form("#relationship-add-form", rel: %{phrase: phrase, query: target_id})
    |> render_change()

    if Keyword.get(opts, :select, true) do
      view |> element("#rel-candidate-#{target_id} button") |> render_click()
    end

    view
    |> form("#relationship-add-form",
      rel: %{phrase: phrase, query: target_id, note: Keyword.get(opts, :note, "")}
    )
    |> render_submit()
  end

  describe "the + add affordance" do
    test "opens the modal from the RELATIONSHIPS panel header", %{conn: conn, ws: ws} do
      task = issue(ws)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#relationship-add-modal")
      assert has_element?(view, "#rel-add-open")

      html = view |> element("#rel-add-open") |> render_click()

      assert html =~ "Add a relationship"
      assert has_element?(view, "#relationship-add-form")
      assert has_element?(view, "#rel-phrase")
    end

    # Acceptance #8 — §2.5: editing edges must not require promoting first.
    test "is present, along with a per-row remove, on a Backlog (unrefined) issue",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      other = issue(ws)
      {:ok, edge} = Dependencies.add(task.id, other.id, :depends_on)

      refute task.refined

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#rel-add-open")
      assert has_element?(view, "#rel-remove-#{edge.id}")
    end
  end

  describe "phrases write the documented triple" do
    # Acceptance #1 and #2.
    test "'is blocked by' writes depends_on(this -> target)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws, %{title: "the blocker"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "is_blocked_by", target.id)

      assert edges() == [{:depends_on, task.id, target.id}]
      # The panel repainted without a reload.
      assert html =~ "Blocked by (1)"
      assert html =~ target.id
      refute has_element?(view, "#relationship-add-modal")
    end

    test "'blocks' writes depends_on(target -> this), never a :blocks row",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "blocks", target.id)

      assert edges() == [{:depends_on, target.id, task.id}]
      assert html =~ "Blocks (1)"
    end

    test "'is the parent of' writes parent_of(this -> target)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "is_parent_of", target.id)

      assert edges() == [{:parent_of, task.id, target.id}]
      assert html =~ "Children"
    end

    # Acceptance #2 calls this one out by name.
    test "'is a child of' writes parent_of(target -> this)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "is_child_of", target.id)

      assert edges() == [{:parent_of, target.id, task.id}]
      assert html =~ "Parent (1)"
    end

    test "'relates to' writes relates_to(this -> target)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "relates_to", target.id)

      assert edges() == [{:relates_to, task.id, target.id}]
      assert html =~ "Related (1)"
    end

    test "'was discovered from' writes discovered_from(this -> target)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "discovered_from", target.id)

      assert edges() == [{:discovered_from, task.id, target.id}]
      assert html =~ "Discovered from (1)"
    end

    test "'conflicts with' writes conflicts_with(this -> target)", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "conflicts_with", target.id)

      assert edges() == [{:conflicts_with, task.id, target.id}]
      assert html =~ "Conflicts with (1)"
    end

    test "stamps created_by: dashboard and the optional note", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      add_relationship(view, "is_blocked_by", target.id, note: "needs the migration first")

      [edge] = Ash.read!(Dependency)
      assert edge.created_by == "dashboard"
      assert edge.notes == "needs the migration first"
    end
  end

  describe "typeahead" do
    # Acceptance #3.
    test "matches on id substring and on title substring", %{conn: conn, ws: ws} do
      task = issue(ws)
      by_title = issue(ws, %{title: "zzsentinel title"})
      by_id = issue(ws, %{title: "unrelated"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      html =
        view
        |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: "zzsentinel"})
        |> render_change()

      assert html =~ by_title.id
      refute html =~ by_id.id

      html =
        view
        |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: by_id.id})
        |> render_change()

      assert html =~ by_id.id
      refute has_element?(view, "#rel-candidate-#{by_title.id}")
    end

    test "is scoped to the issue's workspace and excludes the issue itself",
         %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "bd-ws-#{System.unique_integer([:positive])}",
          prefix: "oth"
        })

      task = issue(ws, %{title: "shared-word here"})
      same_ws = issue(ws, %{title: "shared-word sibling"})
      foreign = issue(other_ws, %{title: "shared-word foreigner"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: "shared-word"})
      |> render_change()

      assert has_element?(view, "#rel-candidate-#{same_ws.id}")
      refute has_element?(view, "#rel-candidate-#{foreign.id}")
      refute has_element?(view, "#rel-candidate-#{task.id}")
    end

    test "ranks open candidates above closed ones", %{conn: conn, ws: ws} do
      task = issue(ws)
      closed = issue(ws, %{title: "rankme closed"})
      {:ok, _} = Ash.update(closed, %{}, action: :close)
      open = issue(ws, %{title: "rankme open"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      html =
        view
        |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: "rankme"})
        |> render_change()

      [_, first, second] = String.split(html, ~r/id="rel-candidate-/, parts: 3)
      assert String.starts_with?(first, open.id)
      assert String.starts_with?(second, closed.id)
    end

    test "the search input is debounced", %{conn: conn, ws: ws} do
      task = issue(ws)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      assert has_element?(view, ~s(#rel-query[phx-debounce]))
    end
  end

  describe "pre-checks grey out candidates" do
    # Acceptance #4.
    test "a duplicate edge of the chosen type is not selectable and says why",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws, %{title: "dupe target"})
      {:ok, _} = Dependencies.add(task.id, target.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      html =
        view
        |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: "dupe target"})
        |> render_change()

      assert html =~ "already linked"
      refute has_element?(view, "#rel-candidate-#{target.id} button")

      # …but only for the phrase that would duplicate it.
      view
      |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: "dupe target"})
      |> render_change()

      assert has_element?(view, "#rel-candidate-#{target.id} button")
    end

    test "a candidate that would close a gating cycle is not selectable and says why",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      mid = issue(ws, %{title: "cycle mid"})
      # task -> mid already; "task is blocked by mid" plus "mid is blocked by
      # task" would close the loop, so offering mid under "blocks" is a cycle.
      {:ok, _} = Dependencies.add(task.id, mid.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      html =
        view
        |> form("#relationship-add-form", rel: %{phrase: "blocks", query: "cycle mid"})
        |> render_change()

      assert html =~ "would create a dependency cycle"
      refute has_element?(view, "#rel-candidate-#{mid.id} button")
    end
  end

  describe "facade errors render in the modal" do
    # Acceptance #9.
    test "a pasted cross-workspace id is rejected by name", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "faraway-#{System.unique_integer([:positive])}",
          prefix: "oth"
        })

      task = issue(ws)
      foreign = issue(other_ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "relates_to", foreign.id, select: false)

      assert has_element?(view, "#relationship-add-modal")
      assert html =~ "single workspace"
      assert html =~ other_ws.name
      assert edges() == []
    end

    test "a cycle rejection names the path and links every id", %{conn: conn, ws: ws} do
      task = issue(ws)
      mid = issue(ws)
      {:ok, _} = Dependencies.add(task.id, mid.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "blocks", mid.id, select: false)

      assert html =~ "dependency cycle"
      assert has_element?(view, ~s(#rel-cycle-path a[href="/tasks/#{task.id}"]))
      assert has_element?(view, ~s(#rel-cycle-path a[href="/tasks/#{mid.id}"]))
      assert edges() == [{:depends_on, task.id, mid.id}]
    end

    test "a duplicate that slipped past the pre-check reports 'already linked'",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)
      {:ok, _} = Dependencies.add(task.id, target.id, :relates_to)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "relates_to", target.id, select: false)

      assert html =~ "already linked"
      assert length(edges()) == 1
    end

    test "an unknown id reports not found", %{conn: conn, ws: ws} do
      task = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = add_relationship(view, "relates_to", "bdt-nosuchthing", select: false)

      assert html =~ "not found"
      assert edges() == []
    end
  end

  describe "dispatch-impact warnings" do
    # Acceptance #6 — warning 1.
    test "warns that a dispatchable target leaves the queue, and never disables submit",
         %{conn: conn, ws: ws} do
      task = ready(issue(ws, %{issue_type: :task}))
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()

      assert html =~ "in the dispatch queue"
      assert html =~ "~15s"
      refute has_element?(view, "#rel-submit[disabled]")
    end

    test "no queue warning for a non-gating phrase or an unrefined issue",
         %{conn: conn, ws: ws} do
      task = ready(issue(ws, %{issue_type: :task}))
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "relates_to", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()
      refute html =~ "in the dispatch queue"

      backlog = issue(ws)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{backlog.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()
      refute html =~ "in the dispatch queue"
    end

    test "no queue warning when the gated issue is already blocked by something else",
         %{conn: conn, ws: ws} do
      task = ready(issue(ws, %{issue_type: :task}))
      existing = issue(ws)
      {:ok, _} = Dependencies.add(task.id, existing.id, :depends_on)
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()
      refute html =~ "in the dispatch queue"
    end

    # Warning 2.
    test "warns that a running worker is not stopped, and links the worker page",
         %{conn: conn, ws: ws} do
      task = issue(ws, %{title: "running one"})
      {:ok, task} = Ash.update(task, %{status: :in_progress})
      target = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()

      assert html =~ "will not stop it"
      assert has_element?(view, ~s(#rel-warning-in-progress a[href="/workers/#{task.id}"]))
      refute has_element?(view, "#rel-submit[disabled]")
    end

    test "the in-progress warning follows the gated endpoint, not always this issue",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws)
      {:ok, _} = Ash.update(target, %{status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-add-open") |> render_click()

      # "this blocks target" gates *target*, which is the one running.
      view
      |> form("#relationship-add-form", rel: %{phrase: "blocks", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()
      assert html =~ "will not stop it"
      assert has_element?(view, ~s(#rel-warning-in-progress a[href="/workers/#{target.id}"]))

      # "this is blocked by target" gates *this*, which is open.
      view
      |> form("#relationship-add-form", rel: %{phrase: "is_blocked_by", query: target.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{target.id} button") |> render_click()
      refute html =~ "will not stop it"
    end

    # Warning 3.
    test "warns that attaching a closed child completes an auto_close parent",
         %{conn: conn, ws: ws} do
      parent = issue(ws, %{title: "the epic", auto_close: true})
      child = issue(ws)
      {:ok, _} = Ash.update(child, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_parent_of", query: child.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{child.id} button") |> render_click()

      assert html =~ "will close #{parent.id}"
      refute has_element?(view, "#rel-submit[disabled]")
    end

    test "no auto_close warning when the new child is open or the parent has open children",
         %{conn: conn, ws: ws} do
      parent = issue(ws, %{auto_close: true})
      open_child = issue(ws)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_parent_of", query: open_child.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{open_child.id} button") |> render_click()
      refute html =~ "will close #{parent.id}"

      # A parent without auto_close never warns, even for a closed child.
      plain = issue(ws)
      closed_child = issue(ws)
      {:ok, _} = Ash.update(closed_child, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{plain.id}")
      view |> element("#rel-add-open") |> render_click()

      view
      |> form("#relationship-add-form", rel: %{phrase: "is_parent_of", query: closed_child.id})
      |> render_change()

      html = view |> element("#rel-candidate-#{closed_child.id} button") |> render_click()
      refute html =~ "will close"
    end
  end

  describe "remove" do
    # Acceptance #5.
    test "the row's ⨯ asks to confirm and then removes exactly that edge",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      one = issue(ws)
      two = issue(ws)
      {:ok, edge} = Dependencies.add(task.id, one.id, :depends_on)
      {:ok, _keep} = Dependencies.add(task.id, two.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      html = view |> element("#rel-remove-#{edge.id}") |> render_click()
      assert html =~ "Remove this relationship"
      # Nothing written yet — the ⨯ only opens the confirm.
      assert length(edges()) == 2

      html = view |> element("#rel-remove-confirm") |> render_click()

      assert edges() == [{:depends_on, task.id, two.id}]
      assert html =~ "Blocked by (1)"
      refute has_element?(view, "#relationship-remove-modal")
    end

    # Warning 4 — the mirror of §2.1.
    test "warns that removing the last gating edge makes the issue dispatchable",
         %{conn: conn, ws: ws} do
      task = ready(issue(ws, %{issue_type: :task}))
      blocker = issue(ws)
      {:ok, edge} = Dependencies.add(task.id, blocker.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element("#rel-remove-#{edge.id}") |> render_click()

      assert html =~ "becomes dispatchable"
      assert html =~ "~15s"
    end

    test "no dispatchable warning while another blocker remains", %{conn: conn, ws: ws} do
      task = ready(issue(ws, %{issue_type: :task}))
      one = issue(ws)
      two = issue(ws)
      {:ok, edge} = Dependencies.add(task.id, one.id, :depends_on)
      {:ok, _} = Dependencies.add(task.id, two.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      html = view |> element("#rel-remove-#{edge.id}") |> render_click()

      refute html =~ "becomes dispatchable"
    end

    test "removes a pre-existing :blocks row too", %{conn: conn, ws: ws} do
      task = issue(ws)
      other = issue(ws)
      {:ok, edge} = Dependencies.add(other.id, task.id, :blocks)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-remove-#{edge.id}") |> render_click()
      view |> element("#rel-remove-confirm") |> render_click()

      assert edges() == []
    end

    # Acceptance #5, second half — §4.4's idempotent remove.
    test "an edge another tab already removed reports success and re-renders",
         %{conn: conn, ws: ws} do
      task = issue(ws)
      other = issue(ws)
      {:ok, edge} = Dependencies.add(task.id, other.id, :depends_on)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rel-remove-#{edge.id}") |> render_click()

      # The other tab wins the race.
      {:ok, 1} = Dependencies.remove(task.id, other.id, :depends_on)

      html = view |> element("#rel-remove-confirm") |> render_click()

      assert html =~ "Removed"
      refute html =~ "Blocked by ("
      refute has_element?(view, "#relationship-remove-modal")
    end

    test "a cross-workspace edge renders without a remove affordance", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "bd-ws-#{System.unique_integer([:positive])}",
          prefix: "oth"
        })

      task = issue(ws)
      foreign = issue(other_ws)

      # Written the pre-facade way — the guard refuses to create these now.
      {:ok, edge} =
        Ash.create(Dependency, %{
          from_issue_id: task.id,
          to_issue_id: foreign.id,
          type: :relates_to
        })

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, ~s([data-role="cross-workspace-marker"]))
      refute has_element?(view, "#rel-remove-#{edge.id}")
    end
  end

  describe "two tabs" do
    # Acceptance #7.
    test "a second tab reflects an add and a remove made in the first", %{conn: conn, ws: ws} do
      task = issue(ws)
      target = issue(ws, %{title: "seen from both tabs"})

      {:ok, tab_a, _} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, tab_b, _} = live(conn, ~p"/tasks/#{task.id}")

      refute render(tab_b) =~ "Blocked by ("

      add_relationship(tab_a, "is_blocked_by", target.id)

      html_b = render(tab_b)
      assert html_b =~ "Blocked by (1)"
      assert html_b =~ "seen from both tabs"

      [edge] = Ash.read!(Dependency)
      tab_a |> element("#rel-remove-#{edge.id}") |> render_click()
      tab_a |> element("#rel-remove-confirm") |> render_click()

      refute render(tab_b) =~ "Blocked by ("
    end
  end
end
