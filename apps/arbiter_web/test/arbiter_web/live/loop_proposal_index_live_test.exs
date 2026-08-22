defmodule ArbiterWeb.LoopProposalIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Loop
  alias Arbiter.Skills

  # A candidate that clears the default bar (3 incidents / 2 distinct tasks).
  defp proposed(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %{
      kind: :skill_patch,
      gist: "tighten the test-first skill (#{n})",
      diff: "--- a/skill\n+++ b/skill\n@@ -1 +1 @@\n-old line\n+new line #{n}\n",
      payload: %{},
      category: "category-#{n}",
      target: "target-#{n}",
      scope: :fleet,
      incident_refs: ["r1-#{n}", "r2-#{n}", "r3-#{n}"],
      task_refs: ["bd-a#{n}", "bd-b#{n}"]
    }

    {:ok, row} = Loop.record(Map.merge(base, attrs))
    row
  end

  defp hypothesis(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    proposed(
      Map.merge(
        %{incident_refs: ["only-#{n}"], task_refs: ["bd-solo#{n}"]},
        attrs
      )
    )
  end

  describe "index" do
    test "lists proposals with gist, state and evidence count", %{conn: conn} do
      row = proposed()

      {:ok, _view, html} = live(conn, ~p"/loop")

      assert html =~ ~s(id="loop-proposals")
      assert html =~ row.gist
      assert html =~ "proposed"
      assert html =~ "3i/2t"
    end

    # Amendment D: the dashboard is where a fleet-wide clause gets approved, so
    # its recurring per-dispatch price has to be in the same glance as the
    # evidence that argues for it.
    test "prices a fleet clause's recurring context cost, and marks a task override free",
         %{conn: conn} do
      fleet = proposed()

      task =
        proposed(%{
          kind: :difficulty_override,
          scope: :task,
          gist: "raise difficulty on bd-solo: D1 → D2",
          payload: %{"difficulty" => 2}
        })

      {:ok, _view, html} = live(conn, ~p"/loop")

      assert fleet.context_cost_tokens > 0
      assert html =~ "+#{fleet.context_cost_tokens}ctx"

      assert task.context_cost_tokens == 0
      assert html =~ "free"
    end

    test "shows an empty state with no proposals", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/loop")

      assert html =~ ~s(id="loop-proposals-empty")
      assert html =~ "evidence bar"
    end

    test "shows hypotheses alongside proposals, and the archive only on request", %{conn: conn} do
      hyp = hypothesis()
      {:ok, rejected} = Loop.reject_pending(proposed(), reason: "not worth it")

      {:ok, view, html} = live(conn, ~p"/loop")
      assert html =~ hyp.gist
      refute html =~ rejected.gist

      html =
        view
        |> element("button[phx-click=filter][phx-value-tab=rejected]")
        |> render_click()

      assert html =~ rejected.gist
      refute html =~ hyp.gist
    end

    test "a filter value outside the tabs' options falls back to live", %{conn: conn} do
      hyp = hypothesis()
      {:ok, view, _html} = live(conn, ~p"/loop")

      # The phx-click payload is client-controlled; an unknown value must not
      # reach String.to_existing_atom/1 and take the LiveView down with it.
      html = render_click(view, :filter, %{"tab" => "no-such-state-#{System.unique_integer()}"})

      assert html =~ hyp.gist
      assert Process.alive?(view.pid)
    end
  end

  describe "live refresh" do
    test "picks up a proposal recorded while the page is open", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/loop")
      refute html =~ "arrived after mount"

      proposed(%{gist: "arrived after mount"})

      assert render(view) =~ "arrived after mount"
    end
  end

  describe "detail pane" do
    test "renders the full unified diff for the selected proposal", %{conn: conn} do
      row = proposed()

      {:ok, view, html} = live(conn, ~p"/loop")
      refute html =~ "new line"

      html = view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      assert html =~ "+new line"
      assert html =~ "--- a/skill"
      assert html =~ row.fingerprint
    end

    test "names what a hypothesis still needs instead of offering apply", %{conn: conn} do
      row = hypothesis()

      {:ok, view, _html} = live(conn, ~p"/loop")
      html = view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      assert html =~ "1 incident"
      refute html =~ "phx-click=\"apply\""
    end
  end

  describe "apply / reject" do
    test "applying a proposal calls the domain API and marks the row applied", %{conn: conn} do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "loop-live-#{System.unique_integer([:positive])}",
          body: "# before"
        })

      row =
        proposed(%{payload: %{"skill" => skill.name, "body" => "# after the loop applied it"}})

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      html = view |> element("button[phx-click=apply]") |> render_click()

      assert html =~ "applied"
      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.body == "# after the loop applied it"

      {:ok, after_apply} = Loop.get_pending(row.id)
      assert after_apply.state == :applied
    end

    test "an apply that the domain refuses surfaces the reason and leaves the row proposed", %{
      conn: conn
    } do
      # No `skill` key in the payload: Stage 3 has not mapped categories to
      # skills yet, so the apply path refuses rather than guessing.
      row = proposed(%{payload: %{}})

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      html = view |> element("button[phx-click=apply]") |> render_click()

      assert html =~ "authored"
      {:ok, unchanged} = Loop.get_pending(row.id)
      assert unchanged.state == :proposed
    end

    test "rejecting is soft — the row persists with its reason", %{conn: conn} do
      row = proposed()

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      view
      |> form("form[phx-submit=reject]", %{"reason" => "handled in CLAUDE.md instead"})
      |> render_submit()

      {:ok, after_reject} = Loop.get_pending(row.id)
      assert after_reject.state == :rejected
      assert after_reject.rejection_reason == "handled in CLAUDE.md instead"
    end
  end

  describe "decided rows stay visible, dimmed" do
    test "an applied row stays in the live filter, dimmed, with a dismiss toast — until dismissed",
         %{conn: conn} do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "loop-live-#{System.unique_integer([:positive])}",
          body: "# before"
        })

      row = proposed(%{payload: %{"skill" => skill.name, "body" => "# after"}})

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()

      html = view |> element("button[phx-click=apply]") |> render_click()

      # The live filter excludes :applied rows from a fresh query — but this
      # one was *just* decided in this session, so it must not vanish.
      assert html =~ row.gist
      assert html =~ ~s(data-decided="applied")
      assert html =~ "Dismiss"
      # The toast only hides the row — it never claims to undo the write.
      refute html =~ "Undo"

      html = view |> element("[phx-click=dismiss_decision]") |> render_click()

      refute html =~ row.gist
    end

    test "dismiss clears every decided row in this session, not just the most recently toasted",
         %{conn: conn} do
      row_a = proposed()
      row_b = proposed()

      {:ok, view, _html} = live(conn, ~p"/loop")

      view |> element("button[phx-value-id='#{row_a.id}']", "Review") |> render_click()
      view |> form("form[phx-submit=reject]") |> render_submit()

      view |> element("button[phx-value-id='#{row_b.id}']", "Review") |> render_click()
      html = view |> form("form[phx-submit=reject]") |> render_submit()

      # Both are dimmed and visible even though only the most recent toast shows.
      assert html =~ row_a.gist
      assert html =~ row_b.gist

      html = view |> element("[phx-click=dismiss_decision]") |> render_click()

      refute html =~ row_a.gist
      refute html =~ row_b.gist
    end

    test "switching filters clears decided rows so they don't leak into other filters",
         %{conn: conn} do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "loop-live-#{System.unique_integer([:positive])}",
          body: "# before"
        })

      row = proposed(%{payload: %{"skill" => skill.name, "body" => "# after"}})

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{row.id}']", "Review") |> render_click()
      view |> element("button[phx-click=apply]") |> render_click()

      html =
        view
        |> element("button[phx-click=filter][phx-value-tab=rejected]")
        |> render_click()

      # The applied row must not leak into an unrelated filter's list or count.
      refute html =~ row.gist
    end

    test "a decided row keeps its created_at-sorted position instead of jumping to the bottom",
         %{conn: conn} do
      older = proposed()

      {:ok, view, _html} = live(conn, ~p"/loop")
      view |> element("button[phx-value-id='#{older.id}']", "Review") |> render_click()
      view |> element("button[phx-click=apply]") |> render_click()

      newer = proposed()
      html = render(view)

      {older_pos, _} = :binary.match(html, older.gist)
      {newer_pos, _} = :binary.match(html, newer.gist)

      assert newer_pos < older_pos
    end

    test "applying an already-applied proposal is a no-op, not an error", %{conn: conn} do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "loop-live-#{System.unique_integer([:positive])}",
          body: "# before"
        })

      row = proposed(%{payload: %{"skill" => skill.name, "body" => "# after"}})
      {:ok, _already_applied} = Loop.apply_pending(row.id, actor: "test-setup")

      {:ok, view, _html} = live(conn, ~p"/loop")

      # Simulate a stray double-click race: the event fires even though the
      # apply button for an already-decided row isn't normally reachable.
      html = render_click(view, "apply", %{"id" => row.id})

      refute html =~ "only a :proposed row can be applied"
      assert Process.alive?(view.pid)

      {:ok, unchanged} = Loop.get_pending(row.id)
      assert unchanged.state == :applied
    end

    test "rejecting an already-rejected proposal is a no-op, not an error", %{conn: conn} do
      row = proposed()
      {:ok, _already_rejected} = Loop.reject_pending(row.id, actor: "test-setup")

      {:ok, view, _html} = live(conn, ~p"/loop")

      html = render_click(view, "reject", %{"id" => row.id})

      refute html =~ "nothing to reject"
      assert Process.alive?(view.pid)

      {:ok, unchanged} = Loop.get_pending(row.id)
      assert unchanged.state == :rejected
    end
  end
end
