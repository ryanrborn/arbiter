defmodule Arbiter.Workflows.PRPatrolTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workflows.PRPatrol
  require Ash.Query

  # PRPatrol now routes forge calls through the MR adapter (Arbiter.Mergers.Github),
  # whose Req plug is Arbiter.Mergers.Github.HTTP — not the old Arbiter.GitHub.HTTP.
  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "prpatrol-#{System.unique_integer([:positive])}",
        prefix: "pp",
        # PRPatrol now resolves its forge adapter from the workspace's merge
        # strategy (provider-agnostic, via the MR adapter). Without a github
        # merge config the strategy is :direct, which has no `list_open/0`, so
        # every tick no-ops and the task-creation tests pass vacuously. Configure
        # github here so the tick tests exercise the real adapter path.
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "owner",
              "repo" => "repo",
              "credentials_ref" => "env:GITHUB_TOKEN"
            }
          }
        }
      })

    # `:github_http_stub` is set globally in config/test.exs; don't touch it.
    # GITHUB_TOKEN is what GitHub.fetch_token!/1 checks; PRPatrol calls
    # GitHub without `opts[:token]` so we need the env var set somewhere.
    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-prpatrol")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp start_patrol(ws, opts \\ []) do
    name = String.to_atom("PRPatrol_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      PRPatrol.start_link(
        Keyword.merge(
          [
            repo: "owner/repo",
            workspace_id: ws.id,
            interval_ms: 60_000,
            name: name
          ],
          opts
        )
      )

    # Let the GenServer process see this test process's Req.Test stub.
    Req.Test.allow(@stub_name, self(), pid)

    {pid, name}
  end

  describe "start_link/1" do
    test "starts with given config", %{ws: ws} do
      {_pid, name} = start_patrol(ws)
      snap = PRPatrol.state(name)
      assert snap.repo == "owner/repo"
      assert snap.workspace_id == ws.id
      assert snap.ticks == 0
    end
  end

  describe "tick/1 — no actionable PRs" do
    test "empty PR list → no tasks created", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).ticks == 1

      assert tasks_for_repo() == []
    end

    test "PR with all-APPROVED reviews → no task", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 41, "title" => "ok", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/41/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "APPROVED"}])

          conn.request_path == "/repos/owner/repo/pulls/41/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end
  end

  describe "tick/1 — actionable PRs" do
    test "CHANGES_REQUESTED → 1 task created, worker spawned", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 42, "title" => "needs work", "html_url" => "https://gh/pr/42"}
            ])

          conn.request_path == "/repos/owner/repo/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}}])

          conn.request_path == "/repos/owner/repo/pulls/42/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.tracker_type == :github
      assert task.tracker_ref == "42"
      assert task.title =~ "PR #42"
      assert task.workspace_id == ws.id

      # Worker is registered for this task
      assert is_pid(Worker.whereis(task.id))
    end

    test "dedup: second tick with the same actionable PR does NOT create another task", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 43, "title" => "twice", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/43/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/43/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      assert length(tasks_for_repo()) == 1
    end

    test "closed follow-up task does not block re-dispatch on a new CHANGES_REQUESTED",
         %{ws: ws} do
      # Task exists but is closed → dedup must not skip the dispatch.
      {:ok, old} =
        Ash.create(Issue, %{
          title: "old PR follow-up",
          tracker_type: :github,
          tracker_ref: "44",
          workspace_id: ws.id
        })

      {:ok, _closed} = Ash.update(old, %{}, action: :close)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 44, "title" => "back again", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/44/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/44/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      open_tasks = tasks_for_repo() |> Enum.filter(&(&1.status != :closed))
      assert length(open_tasks) == 1
    end
  end

  describe "periodic ticking" do
    test "the :tick message reschedules itself", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws, interval_ms: 50)

      # Wait long enough for at least 2 fires (first at ~50ms, second at ~100ms)
      Process.sleep(250)

      assert PRPatrol.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{PRPatrol.state(name).ticks}"
    end
  end

  describe "tick/1 — error handling" do
    test "GitHub list API failure → bumps tick counter, does not crash", %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).ticks == 1
      assert tasks_for_repo() == []
    end
  end

  # ---- helpers ----

  defp tasks_for_repo do
    Issue
    |> Ash.Query.filter(tracker_type == :github)
    |> Ash.read!()
  end
end
