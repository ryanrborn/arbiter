defmodule Arbiter.Worker.ReviewGatePatrolCollisionTest do
  @moduledoc """
  bd-bq8c8a / #1860 — the reported sequence, end to end, with a real
  `Arbiter.Worker.ReviewGate` and a real `Arbiter.Workflows.PRPatrol` on one
  branch.

  `lt-20r7zu`, `admin_server` PR #424, 2026-09-17:

  | time  | actor | event |
  |-------|-------|-------|
  | 16:16 | gate  | round 1 starts |
  | 16:19 | Copilot | two inline review comments on #424 |
  | 16:29 | gate  | round 1 `request_changes`; `#impl1` starts on the worktree |
  | 16:30:10 | patrol fix worker | commits and **pushes** to `origin/<branch>` |
  | 16:30:30 | gate `#impl1` | commits locally |
  | 16:30:38 | gate  | push `:diverged`; task parked `head_not_pushed` |

  Here the reviewer pauses at a handshake so the patrol tick lands while round 1
  is genuinely in flight — the 16:19→16:30 window. What is asserted is the
  absence of the incident: the patrol files nothing, the gate's fix round pushes
  cleanly (no `:diverged`), and the task is never parked `head_not_pushed`.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.CircuitBreaker
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workflows.PRPatrol

  @handshake Path.expand("../../fixtures/review_handshake.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-collision")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-coll-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"owner/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-coll-#{System.unique_integer([:positive])}",
        prefix: "rc",
        config: %{
          "review" => %{"required" => true},
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

    %{repo: repo, ws: ws, tmp: tmp}
  end

  # ---- git rig -------------------------------------------------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    git!(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], repo)
    git!(["commit", "-q", "-m", "feature work"], repo)
    git!(["checkout", "-q", "main"], repo)
    :ok
  end

  defp branch_worktree(repo, tmp, branch) do
    wt = Path.join(tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    wt
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # ---- forge stub ----------------------------------------------------------

  # PR 424: a COMMENTED review leaving two unresolved inline threads — the
  # 16:19:10 Copilot comments, and PRPatrol's actual trigger in the incident.
  defp copilot_stub do
    node = %{
      "reviews" => %{
        "nodes" => [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}]
      },
      "reviewThreads" => %{
        "nodes" => [
          thread("RT_1", "priv/repo/migrations/x.exs", "this column is not nullable"),
          thread("RT_2", "test/support/mock_catalog.ex", "the mock catalog now has 5 rows")
        ]
      },
      "commits" => %{
        "nodes" => [%{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => []}}}}]
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

            {update_in(
               data,
               [cur],
               &Map.put(&1 || %{}, palias, by_number[String.to_integer(num)])
             ), cur}

          true ->
            {data, cur}
        end
      end)

    %{"data" => data}
  end

  # ---- app rig -------------------------------------------------------------

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "VR-19006 catalog", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    {:ok, task} = Ash.update(task, %{pr_ref: "owner/repo#424"}, action: :update)
    task
  end

  defp start_author(task, ws, repo, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "owner/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(author)) end)
    author
  end

  defp start_patrol(ws) do
    name = String.to_atom("PRPatrolColl_#{System.unique_integer([:positive])}")

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

  defp rounds(task_id) do
    Round |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  test "patrol stays off the branch while the gate runs, and the fix round pushes cleanly",
       %{repo: repo, ws: ws, tmp: tmp} do
    task = new_task(ws)
    branch = "feature/VR-19006-catalog"
    :ok = seed_feature_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)
    git!(["push", "-q", "-u", "origin", branch], wt)
    round1_head = sha(wt, "HEAD")

    hold = Path.join(tmp, "handshake")
    File.mkdir_p!(hold)

    Req.Test.stub(@stub_name, copilot_stub())

    author = start_author(task, ws, repo, branch, wt)

    gate =
      start_gate(author, task, ws, branch, wt,
        command: [@handshake, branch, hold],
        revise_command: [@revise_commit]
      )

    # 16:16 — round 1 is genuinely in flight and holding.
    wait_until(fn -> File.exists?(Path.join(hold, "ready.1")) end, 20_000)

    # 16:19 — Copilot comments land. PRPatrol sees them and must decline: the
    # gate owns this branch. This is the dispatch that pushed `aed4457`.
    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert follow_ups() == [],
           "PRPatrol dispatched a fix worker onto a branch the ReviewGate was holding"

    # 16:29 — release round 1: REQUEST_CHANGES, then the gate's own fix round
    # commits on the worktree and pushes before round 2 reads it.
    File.write!(Path.join(hold, "go.1"), "")
    wait_until(fn -> File.exists?(Path.join(hold, "ready.2")) end, 30_000)

    fix_head = sha(wt, "HEAD")
    refute fix_head == round1_head, "the fix round produced no commit"

    # The push landed: not `:diverged`, and origin carries the fix.
    git!(["fetch", "-q", "origin"], repo)
    assert sha(repo, "origin/" <> branch) == fix_head

    # And the task was never parked.
    assert Ash.get!(Issue, task.id).review_park_reason == nil
    assert Enum.any?(rounds(task.id), &(&1.role == :impl))

    # Stop before the APPROVE so the author never enters the merge path — the
    # merge is not what this test is about.
    if Process.alive?(gate), do: GenServer.stop(gate, :normal)
    File.write!(Path.join(hold, "go.2"), "")
  end

  defp start_gate(author, task, ws, branch, wt, opts) do
    {:ok, gate} =
      ReviewGate.start(
        [
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "owner/repo",
          worktree_path: wt,
          branch: branch,
          target_branch: "main",
          timeout_ms: 60_000
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(gate), do: GenServer.stop(gate, :normal) end)
    gate
  end
end
