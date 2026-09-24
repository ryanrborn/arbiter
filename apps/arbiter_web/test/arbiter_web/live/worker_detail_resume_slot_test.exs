defmodule ArbiterWeb.WorkerDetailResumeSlotTest do
  @moduledoc """
  bd-92mx1m acceptance 2 on the worker-detail Retry/Resume modal: resuming a
  task that released its slot, at a full cap, is refused inline with the cap
  and the slot-holding tasks, and the modal then offers an explicit
  over-the-cap resume, which is recorded.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wd-resume-slot-#{System.unique_integer([:positive])}",
        prefix: "wds#{System.unique_integer([:positive])}"
      })

    Map.put(ResumeSlotFixture.setup_incident(ws), :ws, ws)
  end

  test "Resume at a full cap is refused inline, naming the cap and the holder",
       %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/workers/#{ctx.a.id}")
    view |> element("#worker-toolbar-resume-btn") |> render_click()
    refute has_element?(view, "#worker-retry-force-btn")

    render_click(view, "retry")
    html = render_async(view, 10_000)

    assert html =~ "cap is 1"
    assert html =~ ctx.b.id
    assert has_element?(view, "#worker-retry-modal")
    assert has_element?(view, "#worker-retry-force-btn")
    assert Worker.whereis(ctx.a.id) == ctx.first.worker_pid
    assert ResumeSlotFixture.overrides(ctx.ws) == []
  end

  test "the explicit over-the-cap resume goes through and is recorded", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/workers/#{ctx.a.id}")
    view |> element("#worker-toolbar-resume-btn") |> render_click()
    render_click(view, "retry")
    render_async(view, 10_000)

    view |> element("#worker-retry-force-btn") |> render_click()
    html = render_async(view, 10_000)

    assert html =~ "Resumed #{ctx.a.id}"
    refute has_element?(view, "#worker-retry-modal")
    assert Worker.whereis(ctx.a.id) != ctx.first.worker_pid

    assert [event] = ResumeSlotFixture.overrides(ctx.ws)
    assert event.payload["actor"] == "dashboard"
  end
end
