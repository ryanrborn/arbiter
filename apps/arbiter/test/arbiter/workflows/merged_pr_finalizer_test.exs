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

  # Modern PRPatrol follow-up: source_pr set, tracker_type: :none, no pr_ref.
  defp create_follow_up_task(ws, source_pr_number, opts \\ []) do
    create_attrs =
      opts
      |> Keyword.merge(
        title: "PR ##{source_pr_number}: needs follow-up",
        workspace_id: ws.id,
        tracker_type: :none,
        source_pr: to_string(source_pr_number)
      )
      |> Map.new()

    {:ok, task} = Ash.create(Issue, create_attrs)
    task
  end

  # Legacy PRPatrol follow-up: tracker_type: :github, tracker_ref = PR number,
  # no source_pr, no pr_ref.
  defp create_legacy_follow_up_task(ws, source_pr_number, opts \\ []) do
    create_attrs =
      opts
      |> Keyword.merge(
        title: "PR ##{source_pr_number}: needs follow-up",
        workspace_id: ws.id,
        tracker_type: :github,
        tracker_ref: to_string(source_pr_number)
      )
      |> Map.new()

    {:ok, task} = Ash.create(Issue, create_attrs)
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

  describe "tick/1 — PRPatrol follow-ups (modern source_pr format)" do
    test "merged source PR → follow-up task closed", %{ws: ws} do
      task = create_follow_up_task(ws, 500)
      stub(pr_get_stub(500, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
    end

    test "open source PR → follow-up task stays open", %{ws: ws} do
      task = create_follow_up_task(ws, 501)
      stub(pr_get_stub(501, :open))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status != :closed
    end

    test "merged source PR, already-closed follow-up → no crash", %{ws: ws} do
      task = create_follow_up_task(ws, 502)
      {:ok, _} = Ash.update(task, %{}, action: :close)
      stub(pr_get_stub(502, :merged))

      {_pid, name} = start_finalizer(ws)
      assert :ok = MergedPRFinalizer.tick(name)
      assert MergedPRFinalizer.state(name).ticks == 1
    end

    test "no Sync.lifecycle / no upstream transition for tracker_type: :none", %{ws: ws} do
      # tracker_type: :none → Sync.lifecycle is a no-op regardless, but the
      # critical property is that finalize_follow_up never calls it at all.
      # We verify by stubbing only the PR GET endpoint (no tracker call stub)
      # and confirming the task is closed without error.
      task = create_follow_up_task(ws, 503, tracker_type: :none)
      stub(pr_get_stub(503, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
    end

    test "pr_ref path is unaffected — existing pr_ref task still finalized normally", %{ws: ws} do
      follow_up = create_follow_up_task(ws, 504)
      pr_ref_task = create_task(ws, "505")

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls/504" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 504, "merged" => true, "state" => "closed"})

          conn.request_path == "/repos/owner/repo/pulls/504/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.request_path == "/repos/owner/repo/pulls/505" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 505, "merged" => true, "state" => "closed"})

          conn.request_path == "/repos/owner/repo/pulls/505/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, follow_up_closed} = Ash.get(Issue, follow_up.id)
      {:ok, pr_ref_closed} = Ash.get(Issue, pr_ref_task.id)

      assert follow_up_closed.status == :closed
      assert pr_ref_closed.status == :closed
    end

    test "source_pr follow-up with pr_ref set is excluded (handled by pr_ref pass)", %{ws: ws} do
      # When a follow-up has its own PR opened (pr_ref set), the source_pr sweep
      # must not close it — the pr_ref pass owns finalization for these tasks.
      task = create_follow_up_task(ws, 510)
      {:ok, task} = Ash.update(task, %{pr_ref: "511"}, action: :update)

      # Stub source PR 510 as merged but follow-up's own PR 511 as open.
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls/510" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 510, "merged" => true, "state" => "closed"})

          conn.request_path == "/repos/owner/repo/pulls/510/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.request_path == "/repos/owner/repo/pulls/511" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 511, "merged" => false, "state" => "open"})

          conn.request_path == "/repos/owner/repo/pulls/511/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      # pr_ref=511 is open → task stays open; source_pr sweep skipped this task
      assert refreshed.status != :closed
    end

    test "review_only engagement with source_pr set is excluded", %{ws: ws} do
      # ReviewPatrol engagements share the source_pr field with follow-ups but
      # must never be closed by the MergedPRFinalizer sweep (disjointness invariant).
      {:ok, engagement} =
        Ash.create(Issue, %{
          title: "review engagement for PR #512",
          workspace_id: ws.id,
          tracker_type: :none,
          source_pr: "512"
        })

      {:ok, engagement} = Ash.update(engagement, %{review_only: true}, action: :update)

      stub(pr_get_stub(512, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, engagement.id)
      assert refreshed.status != :closed
    end
  end

  describe "tick/1 — PRPatrol follow-ups (legacy tracker_ref format)" do
    test "merged source PR → legacy follow-up task closed", %{ws: ws} do
      task = create_legacy_follow_up_task(ws, 600)
      stub(pr_get_stub(600, :merged))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status == :closed
    end

    test "open source PR → legacy follow-up task stays open", %{ws: ws} do
      task = create_legacy_follow_up_task(ws, 601)
      stub(pr_get_stub(601, :open))

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status != :closed
    end

    test "404 for tracker_ref → task left open, no crash (safety net for real issue refs)", %{
      ws: ws
    } do
      task = create_legacy_follow_up_task(ws, 602)

      stub(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      {_pid, name} = start_finalizer(ws)
      assert :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      assert refreshed.status != :closed
    end

    test "legacy follow-up with pr_ref set is excluded (handled by pr_ref pass)", %{ws: ws} do
      # When a legacy follow-up has its own PR opened (pr_ref set), the
      # legacy sweep excludes it — the pr_ref pass handles finalization.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR #603: needs follow-up",
          workspace_id: ws.id,
          tracker_type: :github,
          tracker_ref: "603"
        })

      {:ok, task} = Ash.update(task, %{pr_ref: "604"}, action: :update)

      # Source PR 603 is merged but legacy sweep should NOT close it via
      # tracker_ref — the pr_ref pass handles pr_ref=604.
      # We stub 603 as merged and 604 as open to verify the legacy sweep
      # skips tasks with pr_ref set.
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls/603" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 603, "merged" => true, "state" => "closed"})

          conn.request_path == "/repos/owner/repo/pulls/603/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.request_path == "/repos/owner/repo/pulls/604" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 604, "merged" => false, "state" => "open"})

          conn.request_path == "/repos/owner/repo/pulls/604/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      {:ok, refreshed} = Ash.get(Issue, task.id)
      # pr_ref=604 is open → task stays open; legacy sweep skipped this task
      assert refreshed.status != :closed
    end
  end
end
