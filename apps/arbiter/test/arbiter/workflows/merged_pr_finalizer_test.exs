defmodule Arbiter.Workflows.MergedPRFinalizerTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.MergedPRFinalizer
  require Ash.Query

  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mpf-#{System.unique_integer([:positive])}",
        prefix: "mpf#{System.unique_integer([:positive])}",
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

    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-mpf")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, ws: ws}
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  defp start_finalizer(ws, opts \\ []) do
    name = String.to_atom("MergedPRFinalizer_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {MergedPRFinalizer,
         Keyword.merge(
           [
             repo: "owner/repo",
             workspace_id: ws.id,
             interval_ms: 60_000,
             name: name
           ],
           opts
         )}
      )

    Req.Test.allow(@stub_name, self(), pid)
    {pid, name}
  end

  defp create_task(ws, pr_ref, opts \\ []) do
    create_attrs =
      opts
      |> Keyword.drop([:pr_ref])
      |> Keyword.merge(title: "task with pr_ref=#{pr_ref}", workspace_id: ws.id)
      |> Map.new()

    {:ok, task} = Ash.create(Issue, create_attrs)
    {:ok, task} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)
    task
  end

  # Minimal GitHub PR GET stub — returns merged or open.
  defp pr_get_stub(number, status) do
    merged = status == :merged

    fn conn ->
      cond do
        conn.request_path == "/repos/owner/repo/pulls/#{number}" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "number" => number,
            "merged" => merged,
            "state" => if(merged, do: "closed", else: "open"),
            "html_url" => "https://github.com/owner/repo/pull/#{number}"
          })

        conn.request_path == "/repos/owner/repo/pulls/#{number}/reviews" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end
    end
  end

  describe "start_link/1" do
    test "starts with given config", %{ws: ws} do
      {_pid, name} = start_finalizer(ws)
      snap = MergedPRFinalizer.state(name)
      assert snap.repo == "owner/repo"
      assert snap.workspace_id == ws.id
      assert snap.ticks == 0
    end
  end

  describe "tick/1 — no tasks" do
    test "no open tasks with pr_ref → no-op, bumps ticks", %{ws: ws} do
      stub(fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{}) end)

      {_pid, name} = start_finalizer(ws)
      assert :ok = MergedPRFinalizer.tick(name)
      assert MergedPRFinalizer.state(name).ticks == 1
    end
  end

  describe "tick/1 — open PR (not merged)" do
    test "open PR → task left open", %{ws: ws} do
      task = create_task(ws, "100")
      stub(pr_get_stub(100, :open))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status != :closed
    end
  end

  describe "tick/1 — merged PR" do
    test "merged PR → task closed", %{ws: ws} do
      task = create_task(ws, "200")
      stub(pr_get_stub(200, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
    end

    test "already-closed task is not re-processed", %{ws: ws} do
      task = create_task(ws, "201")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      stub(fn _conn -> raise "adapter should not be called for closed tasks" end)

      {_pid, name} = start_finalizer(ws)

      # Should not call the adapter or crash.
      assert :ok = MergedPRFinalizer.tick(name)
      assert MergedPRFinalizer.state(name).ticks == 1
    end

    test "task with tracker_type: :none → task closed without tracker transition", %{ws: ws} do
      task = create_task(ws, "202", tracker_type: :none)
      stub(pr_get_stub(202, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
    end

    test "second tick after merge → task already closed, no double-close error", %{ws: ws} do
      task = create_task(ws, "203")
      stub(pr_get_stub(203, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)
      # Already closed; second tick should not crash.
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
      assert MergedPRFinalizer.state(name).ticks == 2
    end
  end

  describe "tick/1 — API error" do
    test "adapter.get/1 returns error → task left open, no crash", %{ws: ws} do
      task = create_task(ws, "300")

      stub(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      {_pid, name} = start_finalizer(ws)
      assert :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status != :closed
    end

    test "GitHub API 500 → tick bumps, does not crash", %{ws: ws} do
      _task = create_task(ws, "301")

      stub(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      {_pid, name} = start_finalizer(ws)
      assert :ok = MergedPRFinalizer.tick(name)
      assert MergedPRFinalizer.state(name).ticks == 1
    end
  end

  describe "tick/1 — multiple tasks" do
    test "only merged tasks are closed; open task remains open", %{ws: ws} do
      task_open = create_task(ws, "400")
      task_merged = create_task(ws, "401")

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls/400" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 400, "merged" => false, "state" => "open"})

          conn.request_path == "/repos/owner/repo/pulls/400/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.request_path == "/repos/owner/repo/pulls/401" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 401, "merged" => true, "state" => "closed"})

          conn.request_path == "/repos/owner/repo/pulls/401/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, open_task} = Ash.get(Issue, task_open.id)
      {:ok, closed_task} = Ash.get(Issue, task_merged.id)

      assert open_task.status != :closed
      assert closed_task.status == :closed
    end
  end

  describe "periodic ticking" do
    test "the :tick message reschedules itself", %{ws: ws} do
      stub(fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json([]) end)

      {_pid, name} = start_finalizer(ws, interval_ms: 50)
      Process.sleep(250)

      assert MergedPRFinalizer.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{MergedPRFinalizer.state(name).ticks}"
    end
  end
end
