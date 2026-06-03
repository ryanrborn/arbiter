defmodule ArbiterWeb.PolecatDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pd-ws-#{System.unique_integer([:positive])}", prefix: "pd"})

    {:ok, ws: ws}
  end

  describe "GET /polecats/:bead_id" do
    test "renders the snapshot for a running polecat", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-test", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      :ok = Polecat.report(pid, :output_lines, ["hello", "world", "arb done"])

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ bead.id
      assert html =~ "test/rig"
      assert html =~ "hello"
      assert html =~ "arb done"
    end

    test "tells the user when no polecat is registered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/polecats/no-such-bead")
      assert html =~ "No polecat registered"
    end

    test "updates live when the polecat receives new output", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-live", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, view, html} = live(conn, ~p"/polecats/#{bead.id}")
      refute html =~ "fresh-line"

      # Push an output line via the same PubSub topic the polecat would use.
      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      # Polecat's meta won't actually contain the line because we only
      # broadcast — but the LiveView still re-reads the snapshot on the
      # event. So let's seed the output_lines via report/3 and then
      # broadcast to trigger the refresh.
      :ok = Polecat.report(pid, :output_lines, ["fresh-line"])

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      assert render(view) =~ "fresh-line"
    end

    test "shows the workspace context when the bead exists", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-ws", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")
      assert html =~ "Workspace:"
      assert html =~ ws.name
    end

    test "Stop button kills the polecat and redirects to /", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-stop", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, view, html} = live(conn, ~p"/polecats/#{bead.id}")
      assert html =~ "Stop polecat"

      result = render_click(view, "stop")

      # push_navigate emits a {:live_redirect, ...} return from render_click.
      assert {:error, {:live_redirect, %{to: "/"}}} = result
      assert Polecat.whereis(bead.id) == nil
    end

    test "no Stop button when the polecat is :completed", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-done", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")
      :ok = Polecat.advance(pid, :design)
      :ok = Polecat.complete(pid, :done)

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")
      refute html =~ "Stop polecat"
    end

    test "renders the workflow step bar when a MachineState exists",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-wf", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, bead.id, %{
          bead_id: bead.id,
          worktree_path: nil,
          rig: "r"
        })

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ "Workflow:"
      # Work's first step is :load_context.
      assert html =~ "load_context"
      assert html =~ "submit"
    end

    test "a claude-driven polecat shows live activity, not frozen workflow steps",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-claude", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")

      # Even with a MachineState attached (slung polecats always have one), a
      # claude-driven run must NOT show the never-advancing fixed steps — it
      # shows the live activity derived from the stream instead. See bd-c919xj.
      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, bead.id, %{
          bead_id: bead.id,
          worktree_path: nil,
          rig: "r"
        })

      :ok = Polecat.advance(pid, :claude)
      :ok = Polecat.report(pid, :claude_session, true)
      :ok = Polecat.report(pid, :activity, "running tests")

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ "Live activity"
      assert html =~ "running tests"
      # The misleading frozen workflow card + fixed steps are suppressed.
      refute html =~ "Workflow:"
      refute html =~ "load_context"
    end

    test "live activity badge advances after mount with no manual lifecycle event",
         %{conn: conn, ws: ws} do
      # Regression for bd-c919xj: meta[:activity] updates on every stream line,
      # but that path must also *broadcast* so a mounted view refreshes. Mount
      # first, then have the live session emit a second event that changes the
      # activity label, and assert the badge advances — driven solely by the
      # polecat's own activity-change broadcast, not an injected lifecycle event.
      {:ok, bead} = Ash.create(Issue, %{title: "pd-advance", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")

      cwd = Path.join(System.tmp_dir!(), "pd-advance-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      e1 = Path.join(cwd, "e1.jsonl")
      e2 = Path.join(cwd, "e2.jsonl")

      File.write!(e1, tool_use_event("Edit", %{"file_path" => "/r/widget.ex"}) <> "\n")
      File.write!(e2, tool_use_event("Bash", %{"command" => "mix test"}) <> "\n")

      # Emit the first event, pause, then emit the second. The pause leaves a
      # window to mount the view between the two activities.
      {:ok, _port} =
        Arbiter.Polecat.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "cat #{e1}; sleep 0.4; cat #{e2}"]
        )

      # First activity distilled → mount → badge shows it.
      wait_until(fn ->
        match?(%{label: "editing widget.ex"}, Map.get(Polecat.state(bead.id).meta, :activity))
      end)

      {:ok, view, html} = live(conn, ~p"/polecats/#{bead.id}")
      assert html =~ "editing widget.ex"
      refute html =~ "running tests"

      # Second activity arrives on the live session. When the polecat's state
      # reflects it, its activity-change broadcast has already been delivered to
      # the (subscribed) view's mailbox, so the next render processes it first.
      wait_until(fn ->
        match?(%{label: "running tests"}, Map.get(Polecat.state(bead.id).meta, :activity))
      end)

      assert render(view) =~ "running tests"
    end
  end

  defp tool_use_event(name, input) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "name" => name, "input" => input}]
      }
    })
  end

  defp wait_until(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, step_ms)
  end

  defp do_wait_until(fun, deadline, step_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until/3 timed out")
      else
        Process.sleep(step_ms)
        do_wait_until(fun, deadline, step_ms)
      end
    end
  end
end
