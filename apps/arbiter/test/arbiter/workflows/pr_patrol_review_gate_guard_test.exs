defmodule Arbiter.Workflows.PRPatrolReviewGateGuardTest do
  @moduledoc """
  bd-bq8c8a / #1860 — PRPatrol must not put a fix worker on a branch the
  ReviewGate is holding.

  The reported incident (leotech `lt-20r7zu`, `admin_server` PR #424,
  2026-09-17): the fleet's own PR picked up two inline Copilot comments while
  its task was still parked at `:awaiting_review_gate`. PRPatrol read those as
  an unresolved-thread signal, filed a follow-up and dispatched a fix worker,
  which committed `aed4457` and pushed it to `origin/<branch>`. Twenty seconds
  later the gate's round-1 implementer committed on the worktree, its push was
  rejected `:diverged`, and the task parked `head_not_pushed`.

  The resolution is **hold, not drop**: external comments arriving inside the
  gate window are simply not acted on yet. The threads stay unresolved, so the
  very next tick after the gate converges files the follow-up exactly as it
  always would have.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, ReviewPark, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workflows.PRPatrol

  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pp-gate-#{System.unique_integer([:positive])}",
        prefix: "pg",
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
    System.put_env("GITHUB_TOKEN", "test-token-pp-gate")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    tmp = Path.join(System.tmp_dir!(), "pp-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_path = seed_repo!(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    put_app_env(:arbiter, :repo_paths, %{"owner/repo" => repo_path})

    on_exit(fn ->
      Issue
      |> Ash.Query.filter(not is_nil(source_pr))
      |> Ash.read!()
      |> Enum.each(fn issue ->
        case Worker.whereis(issue.id) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
        end
      end)

      File.rm_rf!(tmp)
    end)

    %{ws: ws}
  end

  defp seed_repo!(tmp) do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    remote = Path.join(tmp, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])
    repo
  end

  # PR 424 with two unresolved inline review comments from an automated
  # reviewer — the exact signal that fired in the incident (a COMMENTED review
  # leaving inline threads, no CHANGES_REQUESTED).
  defp copilot_threads_stub do
    node = %{
      "reviews" => %{
        "nodes" => [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}]
      },
      "reviewThreads" => %{
        "nodes" => [
          thread("RT_1", "priv/repo/migrations/x.exs", "the column is not nullable"),
          thread("RT_2", "test/support/mock_catalog.ex", "the mock catalog now has 5 rows")
        ]
      },
      "commits" => %{
        "nodes" => [
          %{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => []}}}}
        ]
      }
    }

    fn conn ->
      cond do
        conn.request_path == "/repos/owner/repo/pulls" and conn.method == "GET" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json([
            %{
              "number" => 424,
              "title" => "VR-19006 catalog",
              "html_url" => "https://gh/pr/424",
              "user" => %{"login" => "fleet-bot"}
            }
          ])

        conn.method == "POST" and conn.request_path == "/graphql" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          query = Jason.decode!(body)["query"]
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(batch_data(query, %{424 => node}))

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end
  end

  defp thread(id, path, body) do
    %{
      "id" => id,
      "isResolved" => false,
      "path" => path,
      "line" => 3,
      "comments" => %{"nodes" => [%{"body" => body, "author" => %{"login" => "copilot"}}]}
    }
  end

  # Mirror the adapter's aliased batched query back as a data payload.
  defp batch_data(query, by_number) do
    {data, _cur} =
      query
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {data, cur} ->
        cond do
          m = Regex.run(~r/(\w+):\s*repository\(/, line) ->
            [_, ralias] = m
            {Map.put(data, ralias, %{}), ralias}

          m = Regex.run(~r/(\w+):\s*pullRequest\(number:\s*(\d+)\)/, line) ->
            [_, palias, num] = m
            node = Map.get(by_number, String.to_integer(num))
            {update_in(data, [cur], &Map.put(&1 || %{}, palias, node)), cur}

          true ->
            {data, cur}
        end
      end)

    %{"data" => data}
  end

  defp authored_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "VR-19006 catalog",
        issue_type: :feature,
        tracker_type: :none,
        workspace_id: ws.id
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    {:ok, task} = Ash.update(task, %{pr_ref: "owner/repo#424"}, action: :update)
    task
  end

  defp start_patrol(ws) do
    name = String.to_atom("PRPatrolGate_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {PRPatrol,
         [
           repo: "owner/repo",
           workspace_id: ws.id,
           interval_ms: 60_000,
           name: name,
           dispatch_opts: [claude_command: ["sleep", "2"]]
         ]}
      )

    Req.Test.allow(@stub_name, self(), pid)
    name
  end

  defp follow_ups do
    Issue |> Ash.Query.filter(source_pr == "424") |> Ash.read!()
  end

  test "no follow-up is filed while the authoring task is parked at :awaiting_review_gate",
       %{ws: ws} do
    task = authored_task(ws)
    Req.Test.stub(@stub_name, copilot_threads_stub())

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "owner/repo",
        workspace_id: ws.id,
        meta: %{branch: "feature/VR-19006"}
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal, 5_000) end)
    :sys.replace_state(author, &%{&1 | status: :awaiting_review_gate})

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert follow_ups() == [],
           "PRPatrol filed a fix worker onto a branch the ReviewGate is holding"
  end

  test "no follow-up is filed while a gate round is running", %{ws: ws} do
    task = authored_task(ws)
    Req.Test.stub(@stub_name, copilot_threads_stub())

    {:ok, impl} =
      Worker.start(
        task_id: task.id <> "#review#impl1",
        repo: "owner/repo",
        workspace_id: ws.id,
        meta: %{role: :implementer, revises: task.id}
      )

    on_exit(fn -> if Process.alive?(impl), do: GenServer.stop(impl, :normal, 5_000) end)

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert follow_ups() == []
  end

  test "no follow-up is filed while the task is review-parked", %{ws: ws} do
    task = authored_task(ws)
    {:ok, _, _} = ReviewPark.park(task.id, :head_not_pushed)
    Req.Test.stub(@stub_name, copilot_threads_stub())

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert follow_ups() == []
  end

  test "the comments are HELD, not dropped: the follow-up lands once the gate converges",
       %{ws: ws} do
    task = authored_task(ws)
    {:ok, _, _} = ReviewPark.park(task.id, :head_not_pushed)
    Req.Test.stub(@stub_name, copilot_threads_stub())

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)
    assert follow_ups() == []

    # The gate converges: the park clears and no gate worker is registered.
    {:ok, _} = ReviewPark.clear(task.id, :test)

    :ok = PRPatrol.tick(name)

    assert [%Issue{} = follow_up] = follow_ups()
    assert follow_up.description =~ "unresolved review thread"
  end

  test "a PR no task in this workspace authored is unaffected", %{ws: ws} do
    # No `pr_ref` anywhere: an outside contributor's PR is nobody's branch to
    # protect, and the guard must not freeze the patrol for it.
    Req.Test.stub(@stub_name, copilot_threads_stub())

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert [%Issue{}] = follow_ups()
  end
end
