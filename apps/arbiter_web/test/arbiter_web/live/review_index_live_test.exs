defmodule ArbiterWeb.ReviewIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Events
  alias Arbiter.Reviews.Record
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rev-#{System.unique_integer([:positive])}", prefix: "rv"})

    {:ok, ws: ws}
  end

  defp record!(ws, attrs) do
    base = %{
      pr_ref: "github:acme/widgets##{System.unique_integer([:positive])}",
      workspace_id: ws.id,
      strategy: "github",
      status: :completed,
      mode: :auto,
      started_at: DateTime.utc_now()
    }

    {:ok, record} = Ash.create(Record, Map.merge(base, attrs))
    record
  end

  describe "mount" do
    test "renders the header and filters when there are no records", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/reviews")

      assert html =~ "Reviews"
      assert html =~ "No external reviews match"
    end

    test "lists a record's columns", %{conn: conn, ws: ws} do
      record!(ws, %{
        pr_ref: "github:acme/widgets#42",
        pr: "42",
        status: :completed,
        verdict: :approve,
        finding_count: 3,
        cost_usd: 0.12
      })

      {:ok, _view, html} = live(conn, "/reviews")

      assert html =~ "42"
      assert html =~ ws.name
      assert html =~ "github"
      assert html =~ "completed"
      assert html =~ "approve"
    end
  end

  describe "filters" do
    test "workspace filter narrows the list", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "rev-other-#{System.unique_integer([:positive])}",
          prefix: "ro"
        })

      record!(ws, %{pr: "in-ws"})
      record!(other_ws, %{pr: "other-ws"})

      {:ok, view, html} = live(conn, "/reviews")
      assert html =~ "in-ws"
      assert html =~ "other-ws"

      html =
        view
        |> element("form")
        |> render_change(%{"workspace_id" => ws.id, "status" => ""})

      assert html =~ "in-ws"
      refute html =~ "other-ws"
    end

    test "status filter narrows the list", %{conn: conn, ws: ws} do
      record!(ws, %{pr: "running-one", status: :running})
      record!(ws, %{pr: "failed-one", status: :failed, failure_stage: "post"})

      {:ok, view, html} = live(conn, "/reviews")
      assert html =~ "running-one"
      assert html =~ "failed-one"

      html =
        view
        |> element("form")
        |> render_change(%{"workspace_id" => "", "status" => "failed"})

      refute html =~ "running-one"
      assert html =~ "failed-one"
    end
  end

  describe "detail expansion" do
    test "shows findings summary and failure diagnostics for a failed review", %{
      conn: conn,
      ws: ws
    } do
      record =
        record!(ws, %{
          pr: "fails",
          status: :failed,
          findings_summary: "2 findings surfaced before failure",
          failure_stage: "post_comment",
          failure_reason: "forge returned 502"
        })

      {:ok, view, _html} = live(conn, "/reviews")

      html = view |> element("#review-row-#{record.id}") |> render_click()

      assert html =~ "2 findings surfaced before failure"
      assert html =~ "post_comment"
      assert html =~ "forge returned 502"
    end

    test "shows proposed comments for a completed_unposted review", %{conn: conn, ws: ws} do
      record =
        record!(ws, %{
          pr: "unposted",
          status: :completed_unposted,
          mode: :report_only,
          greenlight_status: :pending,
          proposed_comments: [
            %{
              "file" => "lib/foo.ex",
              "line" => 12,
              "severity" => "high",
              "message" => "possible nil deref",
              "body" => "consider a guard clause"
            }
          ]
        })

      {:ok, view, _html} = live(conn, "/reviews")

      html = view |> element("#review-row-#{record.id}") |> render_click()

      assert html =~ "lib/foo.ex"
      assert html =~ "possible nil deref"
      assert html =~ "high"
    end

    test "renders a link to the linked engagement task", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "engagement task", workspace_id: ws.id})

      record = record!(ws, %{pr: "engaged", engagement_id: task.id})

      {:ok, view, _html} = live(conn, "/reviews")

      html = view |> element("#review-row-#{record.id}") |> render_click()

      assert html =~ ~s(href="/tasks/#{task.id}")
    end

    test "collapses again on a second click", %{conn: conn, ws: ws} do
      record = record!(ws, %{pr: "toggle-me", findings_summary: "one finding"})

      {:ok, view, _html} = live(conn, "/reviews")

      html = view |> element("#review-row-#{record.id}") |> render_click()
      assert html =~ "one finding"

      html = view |> element("#review-row-#{record.id}") |> render_click()
      refute html =~ "one finding"
    end
  end

  describe "live updates" do
    test "a running -> completed transition patches the row without a full reload", %{
      conn: conn,
      ws: ws
    } do
      record =
        record!(ws, %{pr: "live-update", status: :running, verdict: nil, finding_count: nil})

      {:ok, view, html} = live(conn, "/reviews")
      assert html =~ "running"

      {:ok, updated} =
        Ash.update(record, %{status: :completed, verdict: :approve, finding_count: 5},
          action: :complete
        )

      Events.broadcast(ws.id, "external_review", %{
        status: "completed",
        pr_ref: updated.pr_ref,
        verdict: :approve,
        finding_count: 5,
        mode: :auto,
        review_record_id: updated.id,
        engagement_id: nil
      })

      html = render(view)

      assert html =~ "completed"
      assert html =~ "approve"
    end
  end
end
