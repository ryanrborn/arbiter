defmodule ArbiterWeb.TaskDetailLiveSpendTest do
  @moduledoc """
  bd-8vnuy3: a running worker's spend on the issue header, refreshed while it
  runs, visibly marked as an in-flight estimate — and the same figure on
  `worker_list` / `worker_show` (MCP) and `GET /api/workers[/:id]` (the JSON
  `arb worker list` / `show` render).

  The worker is real and its agent is a real port (`sleep`), spawned under a
  private `CLAUDE_CONFIG_DIR`, so `agent_live`, `meta.config_dir` and
  `meta.cwd` come from the production spawn path. Only the session JSONL is
  hand-written, where the CLI would write it.
  """

  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "live-spend-hdr-#{System.unique_integer([:positive])}",
        prefix: "lsh#{System.unique_integer([:positive])}"
      })

    root = Path.join(System.tmp_dir!(), "live-spend-hdr-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "worktree")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(root) end)

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    %{ws: ws, config_dir: Path.join(root, "claude"), cwd: cwd, coordinator: coordinator}
  end

  defp task!(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(
          %{title: "live spend", workspace_id: ws.id, difficulty: 2, issue_type: :feature},
          attrs
        )
      )

    task
  end

  defp settle!(ws, task_id, attrs) do
    {:ok, ev} =
      Ash.create(
        Event,
        Map.merge(
          %{
            task_id: task_id,
            base_task_id: task_id,
            source: :task,
            step: :work,
            role: "base",
            workspace_id: ws.id,
            occurred_at: @now
          },
          attrs
        )
      )

    ev
  end

  # A worker whose agent is a live port, spawned the way Dispatch spawns one.
  defp live_worker!(ctx, task_id) do
    {:ok, pid} = Worker.start(task_id: task_id, repo: "test/repo", workspace_id: ctx.ws.id)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task_id, :normal) end)
    :ok = Worker.advance(pid, :implement)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: ctx.cwd,
        command: ["sh", "-c", "sleep 60"],
        env: [{"CLAUDE_CONFIG_DIR", ctx.config_dir}]
      )

    assert %{agent_live: true} = Worker.state(pid)
    pid
  end

  # Append assistant turns (claude-sonnet-5: 100_000 output tokens = $1.00) to
  # the session file the CLI would be writing right now.
  defp spend_live!(ctx, session_id, dollars) do
    dir = Path.join([ctx.config_dir, "projects", ClaudeSessionFile.project_slug(ctx.cwd)])
    File.mkdir_p!(dir)

    line =
      Jason.encode!(%{
        "type" => "assistant",
        "sessionId" => session_id,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "message" => %{
          "id" => "msg-#{System.unique_integer([:positive])}",
          "model" => "claude-sonnet-5",
          "usage" => %{"input_tokens" => 0, "output_tokens" => round(dollars * 100_000)}
        }
      })

    File.write!(Path.join(dir, session_id <> ".jsonl"), line <> "\n", [:append])
  end

  # Save-and-restore, never delete_env: config/test.exs may set it.
  defp with_refresh_ms(ms) do
    previous = Application.fetch_env(:arbiter_web, :live_spend_refresh_ms)
    Application.put_env(:arbiter_web, :live_spend_refresh_ms, ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbiter_web, :live_spend_refresh_ms, value)
        :error -> Application.delete_env(:arbiter_web, :live_spend_refresh_ms)
      end
    end)
  end

  describe "a worker mid-pass" do
    test "the header shows settled + in-flight spend, marked live", %{conn: conn} = ctx do
      task = task!(ctx.ws)
      settle!(ctx.ws, task.id, %{cost_usd: 2.0})
      live_worker!(ctx, task.id)
      spend_live!(ctx, "sid-live", 1.5)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      figure = view |> element("#task-spend-figure") |> render()
      assert figure =~ "$3.50"
      assert has_element?(view, "#task-spend-figure[data-live]")
      assert has_element?(view, "#task-spend-live")
      live_badge = view |> element("#task-spend-live") |> render()
      assert live_badge =~ "$2.00 settled"
      assert live_badge =~ "$1.50 in flight"
    end

    test "the figure climbs on the refresh tick, without a page reload", %{conn: conn} = ctx do
      task = task!(ctx.ws)
      live_worker!(ctx, task.id)
      spend_live!(ctx, "sid-tick", 1.0)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert view |> element("#task-spend-figure") |> render() =~ "$1.00"

      spend_live!(ctx, "sid-tick", 2.25)
      send(view.pid, :refresh_live_spend)

      assert view |> element("#task-spend-figure") |> render() =~ "$3.25"
    end

    test "the page arms its own refresh tick while a pass runs, and re-arms it",
         %{conn: conn} = ctx do
      with_refresh_ms(40)
      task = task!(ctx.ws)
      live_worker!(ctx, task.id)
      spend_live!(ctx, "sid-armed", 1.0)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      :erlang.trace(view.pid, true, [:receive])

      assert_receive {:trace, _, :receive, :refresh_live_spend}, 2_000
      assert_receive {:trace, _, :receive, :refresh_live_spend}, 2_000
    end

    test "worker_list, worker_show and the /api/workers JSON report the page's number",
         %{conn: conn} = ctx do
      task = task!(ctx.ws)
      settle!(ctx.ws, task.id, %{cost_usd: 2.0})
      settle!(ctx.ws, task.id <> "#review", %{cost_usd: 0.5, base_task_id: task.id})
      live_worker!(ctx, task.id)
      spend_live!(ctx, "sid-same", 1.25)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert view |> element("#task-spend-figure") |> render() =~ "$3.75"

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      row = Enum.find(workers, &(&1.task_id == task.id))
      assert row.cost_usd == 3.75
      assert row.cost_live == true
      assert row.cost_live_usd == 1.25
      assert row.cost_settled_usd == 2.5

      assert {:ok, shown} = Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})
      assert shown.cost_usd == 3.75
      assert shown.cost_live == true

      index = conn |> get(~p"/api/workers") |> json_response(200)
      api_row = Enum.find(index["data"], &(&1["task_id"] == task.id))
      assert api_row["cost_usd"] == 3.75
      assert api_row["cost_live"] == true

      api_show = conn |> get(~p"/api/workers/#{task.id}") |> json_response(200)
      assert api_show["cost_usd"] == 3.75
      assert api_show["cost_live"] == true
    end

    test "a torn session file falls back to the settled figure and says so", %{conn: conn} = ctx do
      task = task!(ctx.ws)
      settle!(ctx.ws, task.id, %{cost_usd: 2.0})
      live_worker!(ctx, task.id)
      spend_live!(ctx, "sid-torn", 1.0)

      dir = Path.join([ctx.config_dir, "projects", ClaudeSessionFile.project_slug(ctx.cwd)])
      File.write!(Path.join(dir, "sid-torn.jsonl"), ~s({"type":"assistant","mess), [:append])

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view |> element("#task-spend-figure") |> render() =~ "$2.00"
      assert has_element?(view, "#task-spend-degraded")
    end
  end

  describe "settled and unpriced" do
    test "a settled total carries no live marker", %{conn: conn, ws: ws} do
      task = task!(ws)
      settle!(ws, task.id, %{cost_usd: 4.25})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert view |> element("#task-spend-figure") |> render() =~ "$4.25"
      refute has_element?(view, "#task-spend-figure[data-live]")
      refute has_element?(view, "#task-spend-live")
      refute has_element?(view, "#task-spend-degraded")
    end

    test "a page with no pass in flight does not poll", %{conn: conn, ws: ws} do
      with_refresh_ms(40)
      task = task!(ws)
      settle!(ws, task.id, %{cost_usd: 1.0})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      :erlang.trace(view.pid, true, [:receive])

      refute_receive {:trace, _, :receive, :refresh_live_spend}, 300
    end

    test "an agy-only task reads n/a on the page and on worker_list, never $0.00",
         %{conn: conn, ws: ws, coordinator: coordinator} do
      task = task!(ws)
      settle!(ws, task.id, %{cost_usd: nil, provider: "agy"})

      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task.id, :normal) end)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      figure = view |> element("#task-spend-figure") |> render()
      assert figure =~ "n/a"
      refute figure =~ "$0.00"

      assert {:ok, %{workers: workers}} = Tools.worker_list(coordinator, %{})
      row = Enum.find(workers, &(&1.task_id == task.id))
      assert row.cost_usd == nil
      assert row.cost_unpriced == true

      api_show = conn |> get(~p"/api/workers/#{task.id}") |> json_response(200)
      assert api_show["cost_usd"] == nil
      assert api_show["cost_unpriced"] == true
    end
  end
end
