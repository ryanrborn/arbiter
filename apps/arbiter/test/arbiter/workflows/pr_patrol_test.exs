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

    # PRPatrol now routes follow-up dispatch through the full
    # Dispatch.dispatch/2 pipeline (bd-bi5pn0), which requires a real repo
    # path to provision a worktree. Seed one for "owner/repo" and point
    # start_claude at a "sleep" stand-in so tests never invoke a real `claude`
    # subprocess (mirrors dispatch_test.exs's Claude-session tests).
    tmp = Path.join(System.tmp_dir!(), "prpatrol-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_path = seed_repo!(tmp, "repo")

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    put_app_env(:arbiter, :repo_paths, %{"owner/repo" => repo_path})

    on_exit(fn ->
      # Real dispatches register real Worker GenServers under the app's
      # DynamicSupervisor (not tied to this test's process), so they outlive
      # the test unless stopped explicitly — left running, they'd keep using
      # this test's about-to-be-rolled-back sandbox connection and leak writes
      # into whatever test runs next (mirrors dispatch_test.exs's own
      # per-test `GenServer.stop` cleanup for real Claude-session workers).
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

    {:ok, ws: ws, tmp: tmp}
  end

  defp stub(fun), do: Req.Test.stub(@stub_name, fun)

  # Rewinds the recorded `retry_at` for `pr_number` into the past so the next
  # explicit `tick/1` re-attempts dispatch immediately, without waiting out a
  # real exponential-backoff window (`interval_ms` is kept realistic, e.g.
  # 60_000, so the GenServer's own scheduled tick doesn't race the test and
  # self-terminate via the bd-7tr11p lazy-stop gate — see bd-dtpjlf).
  defp force_retry_now(pid, pr_number) do
    :sys.replace_state(pid, fn state ->
      update_in(state.dispatch_failures[pr_number], fn
        nil -> nil
        entry -> %{entry | retry_at: DateTime.add(DateTime.utc_now(), -1, :second)}
      end)
    end)
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait_until(fun, deadline)
    end
  end

  defp start_patrol(ws, opts \\ []) do
    name = String.to_atom("PRPatrol_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!({PRPatrol,
       Keyword.merge(
         [
           repo: "owner/repo",
           workspace_id: ws.id,
           interval_ms: 60_000,
           name: name,
           # Stand-in for a running `claude --print` session — stays alive
           # long enough to prove Dispatch.dispatch/2 was actually invoked
           # (a live worker + worktree), without shelling out to `claude`.
           dispatch_opts: [claude_command: ["sleep", "2"]]
         ],
         opts
       )})

    # Let the GenServer process see this test process's Req.Test stub.
    Req.Test.allow(@stub_name, self(), pid)

    {pid, name}
  end

  # Real git repo + bare "origin" remote so Dispatch.dispatch/2's worktree
  # provisioning (fetch from origin, branch from origin/<base>) succeeds.
  defp seed_repo!(tmp, sub) do
    repo = Path.join(tmp, sub)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    remote = Path.join(tmp, sub <> "-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

    repo
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
      stub(
        signals_stub(
          pulls: [pull(41, title: "ok")],
          nodes: %{
            41 => pr_node(reviews: [%{"state" => "APPROVED", "author" => %{"login" => "a"}}])
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end
  end

  describe "tick/1 — batched signal request (bd-3byp1n)" do
    test "a multi-PR sweep issues ONE GraphQL request and preserves each trigger class",
         %{ws: ws} do
      graphql = :counters.new(1, [])

      nodes = %{
        # CHANGES_REQUESTED — highest-priority signal
        101 => pr_node(cr: true),
        # COMMENTED only, but one unresolved inline thread (bd-823q7e)
        102 =>
          pr_node(
            reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
            threads: [
              %{
                "id" => "RT_102",
                "isResolved" => false,
                "path" => "lib/x.ex",
                "line" => 3,
                "comments" => %{
                  "nodes" => [%{"body" => "nit", "author" => %{"login" => "copilot"}}]
                }
              }
            ]
          ),
        # APPROVED, one settled+required failing check (bd-ayetel)
        103 =>
          pr_node(
            reviews: [%{"state" => "APPROVED", "author" => %{"login" => "alice"}}],
            contexts: [
              %{
                "__typename" => "CheckRun",
                "name" => "ci-required",
                "status" => "COMPLETED",
                "conclusion" => "FAILURE",
                "isRequired" => true
              }
            ]
          ),
        # Clean: approved, no threads, no failing checks → no task
        104 => pr_node(reviews: [%{"state" => "APPROVED", "author" => %{"login" => "alice"}}])
      }

      stub(
        signals_stub(
          graphql_counter: graphql,
          pulls: [pull(101), pull(102), pull(103), pull(104)],
          nodes: nodes
        )
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert :counters.get(graphql, 1) == 1,
             "a 4-PR sweep must issue exactly ONE GraphQL request, not ~3 per PR"

      by_pr = Map.new(tasks_for_repo(), &{&1.source_pr, &1})
      assert Map.keys(by_pr) |> Enum.sort() == ["101", "102", "103"]

      assert by_pr["101"].description =~ "CHANGES_REQUESTED"
      assert by_pr["102"].description =~ "unresolved review thread"
      assert by_pr["103"].description =~ "required check(s) failing: ci-required"
    end

    test "a fully-deduped sweep issues ZERO GraphQL requests (steady-state)", %{ws: ws} do
      graphql = :counters.new(1, [])

      stub(
        signals_stub(
          graphql_counter: graphql,
          pulls: [pull(110)],
          nodes: %{110 => pr_node(cr: true)}
        )
      )

      {_pid, name} = start_patrol(ws)

      # First tick files the follow-up (one batched request).
      :ok = PRPatrol.tick(name)
      assert :counters.get(graphql, 1) == 1
      assert length(tasks_for_repo()) == 1

      # Second tick: the PR is already deduped, so it never enters the batch —
      # the cheap DB gate short-circuits it and NO GraphQL request is issued.
      :ok = PRPatrol.tick(name)
      assert :counters.get(graphql, 1) == 1, "a deduped PR must not enter the batched request"
      assert length(tasks_for_repo()) == 1
    end

    test "partial batch failure falls back to the per-PR path for the affected PR", %{ws: ws} do
      # PR 120 resolves in the batch; PR 121 comes back null with a top-level
      # error. 121 must still be actioned — via the per-PR fallback callbacks —
      # not silently dropped.
      batch_node = %{120 => pr_node(cr: true)}

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([pull(120), pull(121)])

          # Per-PR fallback for 121: REST review feedback (CHANGES_REQUESTED).
          conn.request_path == "/repos/owner/repo/pulls/121/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED", "user" => %{"login" => "a"}}])

          conn.request_path == "/repos/owner/repo/pulls/121/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            query = Jason.decode!(body)["query"]

            if query =~ ~r/\w+:\s*repository\(/ do
              # Batched query: 120 present, 121 null, plus a top-level error.
              base = batch_data_from_query(query, batch_node)

              conn
              |> Plug.Conn.put_status(200)
              |> Req.Test.json(
                Map.put(base, "errors", [%{"message" => "Could not resolve to PR 121"}])
              )
            else
              # Single-PR fallback GraphQL for 121 (threads / required checks):
              # empty — 121 already triggers on CHANGES_REQUESTED via REST above.
              conn
              |> Plug.Conn.put_status(200)
              |> Req.Test.json(%{
                "data" => %{
                  "repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => []}}}
                }
              })
            end

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      prs = tasks_for_repo() |> Enum.map(& &1.source_pr) |> Enum.sort()
      assert prs == ["120", "121"], "the partial-failure PR must fall back to the per-PR path"
    end
  end

  describe "tick/1 — actionable PRs" do
    test "CHANGES_REQUESTED → 1 task created, worker spawned", %{ws: ws} do
      stub(
        signals_stub(
          pulls: [pull(42, title: "needs work", html_url: "https://gh/pr/42")],
          nodes: %{
            42 =>
              pr_node(
                reviews: [%{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "alice"}}]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      # tracker_type is :none so dispatch never tries to transition the merged
      # PR; the source PR is linked via source_pr instead (bd-ci2jl2). The
      # follow-up is `:task` (bd-6v2my2, NOT :feature/reviewable): it has no
      # branch/PR of its own — `:task`'s default (skip branch-worktree
      # provisioning) is exactly right, so `meta.worktree_path` stays nil.
      assert task.tracker_type == :none
      assert task.source_pr == "42"
      assert task.issue_type == :task
      assert task.title =~ "PR #42"
      assert task.workspace_id == ws.id

      # Worker is registered for this task.
      pid = Worker.whereis(task.id)
      assert is_pid(pid)
      assert %{issue_type: :task, worktree_path: nil} = Worker.state(pid).meta
    end

    test "COMMENTED review with an unresolved review thread → 1 task created, worker spawned",
         %{ws: ws} do
      # The Copilot-on-#3609 case: the review is COMMENTED (not CHANGES_REQUESTED),
      # so changes_requested? is false — but it left an inline comment that lives
      # in an unresolved review thread, which the batched signals surface.
      stub(
        signals_stub(
          pulls: [pull(50, title: "commented only", html_url: "https://gh/pr/50")],
          nodes: %{
            50 =>
              pr_node(
                reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
                threads: [
                  %{
                    "id" => "RT_1",
                    "isResolved" => false,
                    "path" => "lib/x.ex",
                    "line" => 5,
                    "comments" => %{
                      "nodes" => [%{"body" => "nit", "author" => %{"login" => "copilot"}}]
                    }
                  }
                ]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.source_pr == "50"
      assert task.title =~ "PR #50"
      # bd-6v2my2: NOT a reviewable type — no branch/PR of its own.
      assert task.issue_type == :task
      assert task.description =~ "unresolved review thread"
      assert task.description =~ "Review thread follow-up protocol"
      assert task.description =~ "Addressed in <sha>"
      assert is_pid(Worker.whereis(task.id))
    end

    # Regression for bd-6v2my2 / lt-divfvo -> verus_server#3682: a thread-reply
    # follow-up that replies + resolves and pushes zero commits must complete
    # as a SUCCESS with zero new PRs opened on the forge — not the prior
    # behaviour, where the follow-up's own worktree/branch got pushed and
    # turned into a byte-identical duplicate PR the instant it completed.
    test "thread-reply follow-up completing with zero commits opens zero new PRs (bd-6v2my2)",
         %{ws: ws} do
      pulls_posted = :counters.new(1, [])

      node =
        pr_node(
          reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
          threads: [
            %{
              "id" => "RT_1",
              "isResolved" => false,
              "path" => "openspec/changes/x.md",
              "comments" => %{
                "nodes" => [%{"body" => "nit", "author" => %{"login" => "copilot"}}]
              }
            }
          ]
        )

      base =
        signals_stub(
          pulls: [pull(3679, title: "openspec change", html_url: "https://gh/pr/3679")],
          nodes: %{3679 => node}
        )

      stub(fn conn ->
        # A POST to /pulls is a NEW PR being opened — count it (must stay 0).
        if conn.method == "POST" and conn.request_path == "/repos/owner/repo/pulls" do
          :counters.add(pulls_posted, 1, 1)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 999})
        else
          base.(conn)
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.issue_type == :task

      worker_pid = Worker.whereis(task.id)
      assert is_pid(worker_pid)

      # The worker addressed everything via replies/resolves against the
      # ORIGINAL PR and pushed no commits of its own — write a notes summary
      # (as the notes gate requires for a `:task` completion) and signal done.
      {:ok, _} =
        Ash.update(task, %{notes: "Replied to RT_1 and resolved it. No code fix was needed."},
          action: :update
        )

      send(worker_pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(worker_pid)) end)

      assert :counters.get(pulls_posted, 1) == 0,
             "thread-reply follow-up must never open a new PR on the forge"
    end

    test "COMMENTED review with all threads resolved → no task", %{ws: ws} do
      stub(
        signals_stub(
          pulls: [pull(51, title: "resolved", html_url: "x")],
          nodes: %{
            51 =>
              pr_node(
                reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "c"}}],
                threads: [%{"id" => "RT_1", "isResolved" => true, "comments" => %{"nodes" => []}}]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end

    # bd-45x4yo: a thread we already replied to (even though the protocol
    # forbids resolving a wrong-finding-on-a-bot-thread) must not keep
    # re-triggering PRPatrol forever. "We had the last word" is enough to
    # treat the thread as answered, independent of resolve state.
    test "unresolved thread whose last comment is ours → no task (bd-45x4yo)", %{ws: ws} do
      {:ok, ws} =
        Ash.update(ws, %{patch: %{"pr_patrol" => %{"our_login" => "arbiter-bot"}}},
          action: :patch_config
        )

      stub(
        signals_stub(
          pulls: [pull(52, title: "already answered", html_url: "x")],
          nodes: %{
            52 =>
              pr_node(
                reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
                threads: [
                  %{
                    "id" => "RT_1",
                    "isResolved" => false,
                    "comments" => %{
                      "nodes" => [
                        %{"body" => "wrong finding", "author" => %{"login" => "copilot"}},
                        %{
                          "body" => "Addressed: this is wrong, see file:line. Escalating.",
                          "author" => %{"login" => "arbiter-bot"}
                        }
                      ]
                    }
                  }
                ]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end

    test "unresolved thread already answered by us, but WITHOUT our_login configured → still 1 task",
         %{ws: ws} do
      # No config[pr_patrol][our_login] / config[review_patrol][our_login] set
      # on `ws` — PRPatrol can't tell its own replies apart from anyone
      # else's, so it must conservatively keep treating the thread as open
      # (the pre-fix behaviour) rather than silently going quiet.
      stub(
        signals_stub(
          pulls: [pull(53, title: "unconfigured our_login", html_url: "x")],
          nodes: %{
            53 =>
              pr_node(
                reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
                threads: [
                  %{
                    "id" => "RT_1",
                    "isResolved" => false,
                    "comments" => %{
                      "nodes" => [
                        %{"body" => "wrong finding", "author" => %{"login" => "copilot"}},
                        %{"body" => "Addressed: wrong.", "author" => %{"login" => "arbiter-bot"}}
                      ]
                    }
                  }
                ]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert [task] = tasks_for_repo()
      assert task.source_pr == "53"
    end

    test "thread we answered, but a NEW comment landed after ours → still 1 task", %{ws: ws} do
      {:ok, ws} =
        Ash.update(ws, %{patch: %{"pr_patrol" => %{"our_login" => "arbiter-bot"}}},
          action: :patch_config
        )

      stub(
        signals_stub(
          pulls: [pull(54, title: "human pushed back", html_url: "x")],
          nodes: %{
            54 =>
              pr_node(
                reviews: [%{"state" => "COMMENTED", "author" => %{"login" => "copilot"}}],
                threads: [
                  %{
                    "id" => "RT_1",
                    "isResolved" => false,
                    "comments" => %{
                      "nodes" => [
                        %{"body" => "wrong finding", "author" => %{"login" => "copilot"}},
                        %{"body" => "Addressed: wrong.", "author" => %{"login" => "arbiter-bot"}},
                        %{
                          "body" => "Actually I disagree, please reconsider",
                          "author" => %{"login" => "human-reviewer"}
                        }
                      ]
                    }
                  }
                ]
              )
          }
        )
      )

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert [task] = tasks_for_repo()
      assert task.source_pr == "54"
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

    # Regression for bd-4brb2j: once a PR already has an open follow-up,
    # `deduped?/2` (a local DB check) must run BEFORE the three GitHub signal
    # calls (`changes_requested?`, `open_review_thread_count`,
    # `required_check_failure_names`) — not after. The prior ordering paid the
    # full three-call signal check for every open PR on every tick forever,
    # even once nothing new could come of it; that steady per-tick cost was
    # the "inter-sweep trickle" identified in the incident report. This test
    # counts hits on the `/reviews` endpoint (one of the three signal calls)
    # and asserts it is NOT called again once the PR is deduped.
    test "dedup short-circuits BEFORE the GitHub signal calls on a later tick", %{ws: ws} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 46, "title" => "counted", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/46/reviews" ->
            Agent.update(counter, &(&1 + 1))

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/46/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      assert Agent.get(counter, & &1) == 1

      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      assert Agent.get(counter, & &1) == 1,
             "expected the /reviews signal call to fire only on the first (non-deduped) tick"

      assert length(tasks_for_repo()) == 1
    end

    # Regression for bd-ag9pq3. `Arbiter.MCP.Tools.task_update`'s spec never
    # carries a `source_pr` key (verified: `task_update_spec/0` in
    # `mcp/tools/task.ex` has no such entry, so `collect_attrs/2` can never put
    # one in the attrs it hands to `Ash.update/3`) — so that path was never the
    # nulling mechanism. The mechanism that *can* reach `action: :update` with
    # an explicit `source_pr` key is `ArbiterWeb.Api.IssueController.update/2`
    # (`PATCH /api/issues/:id`), which forwards the raw request body — any of
    # `source_pr`, unlike the MCP tool's fixed field allowlist — straight into
    # `Ash.update(issue, attrs)` with no `action:` (i.e. the primary `:update`
    # action). This pins that exact mechanism: before the fix, an explicit
    # `source_pr` in the update attrs (however it got there — a raw API caller,
    # a script round-tripping a differently-shaped payload, anything upstream
    # of the MCP layer) was accepted and could null the dedup linkage; after
    # the fix it must not silently succeed in nulling it.
    test "dedup survives an explicit source_pr write reaching the :update action (bd-ag9pq3)",
         %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 3266, "title" => "retask me", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/3266/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/3266/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.source_pr == "3266"

      # Exactly what `IssueController.update/2` does: forward the raw params
      # straight to `Ash.update/2` with no `action:` override. A caller whose
      # local model of the task doesn't carry `source_pr` (the REST show/index
      # JSON never renders it — see `IssueJSON.data/1`) round-trips it back as
      # `nil`, which is exactly how the incident nulled it.
      patch_attrs = %{
        "title" => "retasked title",
        "description" => "retasked description",
        "source_pr" => nil
      }

      case Ash.update(task, patch_attrs) do
        {:ok, updated} ->
          assert updated.source_pr == "3266"

        {:error, _} ->
          # Rejecting the unaccepted `source_pr` key outright (rather than
          # silently nulling it) is an acceptable fix too — either way the
          # linkage must survive.
          :ok
      end

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.source_pr == "3266"

      :ok = PRPatrol.tick(name)
      assert length(tasks_for_repo()) == 1
    end

    # Regression for bd-5g6rw4: legacy follow-ups recorded the PR via
    # tracker_type: :github + tracker_ref: <pr#> before source_pr existed.
    # deduped?/1 must recognise them so the patrol does not file a duplicate.
    test "dedup: legacy follow-up (tracker_type: :github, tracker_ref) prevents re-dispatch",
         %{ws: ws} do
      {:ok, _legacy} =
        Ash.create(Issue, %{
          title: "old-format follow-up for PR #45",
          tracker_type: :github,
          tracker_ref: "45",
          workspace_id: ws.id
        })

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 45, "title" => "legacy dedup", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/45/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/45/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      # Only the pre-existing legacy bead; no new follow-up was filed.
      all_tasks =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws.id)
        |> Ash.read!()

      assert length(all_tasks) == 1
      assert hd(all_tasks).tracker_ref == "45"
    end

    test "closed follow-up task does not block re-dispatch on a new CHANGES_REQUESTED",
         %{ws: ws} do
      # Task exists but is closed → dedup must not skip the dispatch.
      {:ok, old} =
        Ash.create(Issue, %{
          title: "old PR follow-up",
          tracker_type: :none,
          source_pr: "44",
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

  describe "tick/1 — required check failure trigger (bd-ayetel)" do
    # The PR is APPROVED (no CHANGES_REQUESTED) with no unresolved threads, so
    # the ONLY signal that can fire is a settled+required check failure carried
    # in `contexts`. Fetched through the single batched request (bd-3byp1n).
    defp required_check_stub(number, contexts, opts \\ []) do
      title = Keyword.get(opts, :title, "approved but CI-blocked")

      signals_stub(
        pulls: [pull(number, title: title, html_url: "x")],
        nodes: %{
          number =>
            pr_node(
              reviews: [%{"state" => "APPROVED", "author" => %{"login" => "a"}}],
              contexts: contexts
            )
        }
      )
    end

    test "settled required check FAILURE on an approved PR → 1 task, CI triage protocol included",
         %{ws: ws} do
      stub(
        required_check_stub(70, [
          %{
            "__typename" => "CheckRun",
            "name" => "ui-integration-tests",
            "status" => "COMPLETED",
            "conclusion" => "FAILURE",
            "isRequired" => true
          }
        ])
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.source_pr == "70"
      # bd-6v2my2 audit: the CI-failure trigger gets the same `:task` fix as
      # the review-thread trigger — a fix pushed here must land on the
      # ORIGINAL PR's branch to turn its required check green; a fix on a
      # fresh branch/PR can never do that.
      assert task.issue_type == :task
      assert task.description =~ "required check(s) failing: ui-integration-tests"
      assert task.description =~ "Required-check failure triage protocol"
      assert task.description =~ "FLAKE"
      assert task.description =~ "PRE-EXISTING ON BASE"
      assert task.description =~ "REAL REGRESSION"
      assert is_pid(Worker.whereis(task.id))
    end

    test "failing but OPTIONAL (isRequired=false) check → no task", %{ws: ws} do
      stub(
        required_check_stub(71, [
          %{
            "__typename" => "CheckRun",
            "name" => "optional-lint",
            "status" => "COMPLETED",
            "conclusion" => "FAILURE",
            "isRequired" => false
          }
        ])
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end

    test "required check still IN_PROGRESS (not yet settled) → no task", %{ws: ws} do
      stub(
        required_check_stub(72, [
          %{
            "__typename" => "CheckRun",
            "name" => "build",
            "status" => "IN_PROGRESS",
            "conclusion" => nil,
            "isRequired" => true
          }
        ])
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
    end

    test "dedup: second tick with the same failing required check does NOT create another task",
         %{ws: ws} do
      stub(
        required_check_stub(73, [
          %{
            "__typename" => "CheckRun",
            "name" => "ui-integration-tests",
            "status" => "COMPLETED",
            "conclusion" => "FAILURE",
            "isRequired" => true
          }
        ])
      )

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      assert length(tasks_for_repo()) == 1
    end
  end

  describe "periodic ticking" do
    test "the :tick message reschedules itself", %{ws: ws} do
      # An open fleet-authored PR task keeps the lazy-stop guard (bd-7tr11p)
      # satisfied so the scheduled ticks proceed instead of self-terminating.
      create_pr_task!(ws, "#7")

      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws, interval_ms: 50)

      # Wait long enough for at least 2 fires (first at ~50ms, second at ~100ms)
      Process.sleep(250)

      assert PRPatrol.state(name).ticks >= 2,
             "expected at least 2 auto-ticks; got #{PRPatrol.state(name).ticks}"
    end

    # bd-4brb2j: a patrol that keeps finding nothing actionable must stretch
    # its own cadence out instead of holding the fixed interval forever.
    test "idle_ticks grows on consecutive empty ticks and resets once a PR dispatches",
         %{ws: ws} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {_pid, name} = start_patrol(ws)

      :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).idle_ticks == 1

      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).idle_ticks == 3

      pulls_stub(82, "anyone")
      :ok = PRPatrol.tick(name)
      assert PRPatrol.state(name).idle_ticks == 0
    end
  end

  describe "tick/1 — multi-repo workspace (no repo in config)" do
    test "patrol with explicit repo works when workspace config omits repo field", %{tmp: tmp} do
      # Simulates the leotech multi-repo shape: owner is set, but repo is absent
      # from the workspace merge config. The per-patrol repo ("owner/explicit-repo")
      # must be injected via prepare_with_repo so list_open/0 resolves the correct
      # REST endpoint. Without the fix, list_open/0 would return {:error, config_missing}.
      {:ok, multi_ws} =
        Ash.create(Workspace, %{
          name: "multi-repo-#{System.unique_integer([:positive])}",
          prefix: "mr",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      stub(
        signals_stub(
          repo: "owner/explicit-repo",
          pulls: [pull(60, title: "multi-repo PR", html_url: "https://gh/pr/60")],
          nodes: %{
            60 =>
              pr_node(
                reviews: [%{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "alice"}}]
              )
          }
        )
      )

      name = String.to_atom("PRPatrol_multirepo_#{System.unique_integer([:positive])}")

      explicit_repo_path = seed_repo!(tmp, "explicit-repo")

      repo_paths = Application.get_env(:arbiter, :repo_paths, %{})

      Application.put_env(
        :arbiter,
        :repo_paths,
        Map.put(repo_paths, "owner/explicit-repo", explicit_repo_path)
      )

      pid =
        start_supervised!(
          {PRPatrol,
           [
             repo: "owner/explicit-repo",
             workspace_id: multi_ws.id,
             interval_ms: 60_000,
             name: name,
             dispatch_opts: [claude_command: ["sleep", "2"]]
           ]}
        )

      Req.Test.allow(@stub_name, self(), pid)
      :ok = PRPatrol.tick(name)

      tasks = tasks_for_repo()
      assert length(tasks) == 1
      [task] = tasks
      assert task.source_pr == "60"
      assert task.title =~ "PR #60"
      assert task.workspace_id == multi_ws.id
      assert is_pid(Worker.whereis(task.id))
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

  describe "tick/1 — author allowlist (pr_patrol.author_logins)" do
    setup do
      {:ok, scoped} =
        Ash.create(Workspace, %{
          name: "pp-scoped-#{System.unique_integer([:positive])}",
          prefix: "pps#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            },
            "pr_patrol" => %{"author_logins" => ["me-login"]}
          }
        })

      {:ok, scoped: scoped}
    end

    test "PR by an allowlisted author → task created", %{scoped: ws} do
      pulls_stub(70, "me-login")

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert [task] = tasks_for_repo()
      assert task.source_pr == "70"
    end

    test "PR by a non-allowlisted author → skipped (no task), despite CHANGES_REQUESTED",
         %{scoped: ws} do
      pulls_stub(71, "someone-else")

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert tasks_for_repo() == []
    end

    # Fail-closed: an allowlist IS configured but the PR carries no resolvable
    # author (the `/pulls` payload has no `user` field, so author → nil). The PR
    # must be skipped even though it is otherwise actionable (CHANGES_REQUESTED),
    # because we cannot attribute it to an allowed author (bd-eos7xe / #603).
    test "allowlist set but author unresolvable (nil) → skipped (no task)", %{scoped: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              # No `user` key → author resolves to nil.
              %{"number" => 73, "title" => "t73", "html_url" => "https://gh/pr/73"}
            ])

          conn.request_path == "/repos/owner/repo/pulls/73/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/73/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert tasks_for_repo() == []
    end

    # Back-compat: a workspace with no allowlist patrols all authors. Uses the
    # default `ws` from the outer setup (github merge config, no `pr_patrol` key).
    test "no allowlist configured → PR by any author is patrolled", %{ws: ws} do
      pulls_stub(72, "anyone-at-all")

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert [task] = tasks_for_repo()
      assert task.source_pr == "72"
    end
  end

  describe "config hot-reload — changes take effect without restart" do
    test "adding author_logins after start blocks PRs by non-listed authors on next tick",
         %{ws: ws} do
      # First tick: no allowlist → PR by "anyone" fires a task.
      pulls_stub(80, "anyone")

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert [task] = tasks_for_repo()
      assert task.source_pr == "80"

      # Close the task so dedup won't hide the second tick's behavior.
      {:ok, _} = Ash.update(task, %{}, action: :close)

      # Set author_logins restriction on the live workspace (simulates `arb config set`).
      {:ok, _ws_updated} =
        Ash.update(ws, %{patch: %{"pr_patrol" => %{"author_logins" => ["allowed-only"]}}},
          action: :patch_config
        )

      # Stub a PR by a non-listed author — CHANGES_REQUESTED so it would
      # normally dispatch, but the fresh allowlist should block it.
      pulls_stub(81, "someone-else")

      :ok = PRPatrol.tick(name)

      # Only the closed task from tick 1 exists; no new open task was created.
      open_tasks =
        tasks_for_repo()
        |> Enum.filter(&(&1.status != :closed))

      assert open_tasks == [],
             "expected no open tasks after allowlist applied, got: #{inspect(open_tasks)}"
    end
  end

  describe "tick/1 — dispatch failure handling (bd-bi5pn0)" do
    # The old bare `Worker.start` never failed, so a dispatch error had no
    # handling path. Now that maybe_dispatch/3 routes through
    # Dispatch.dispatch/2, a repo that can't be resolved must close the
    # follow-up (freeing dedup for a retry) and escalate to the coordinator,
    # instead of leaving an idle, worktree-less worker registered forever.
    test "dispatch failure (repo not configured) closes the follow-up and escalates",
         %{ws: _ws} do
      {:ok, unconfigured_ws} =
        Ash.create(Workspace, %{
          name: "pp-unconfigured-#{System.unique_integer([:positive])}",
          prefix: "ppu#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "unconfigured-repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/unconfigured-repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 90, "title" => "no repo path", "html_url" => "x"}
            ])

          conn.request_path == "/repos/owner/unconfigured-repo/pulls/90/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/unconfigured-repo/pulls/90/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      name = String.to_atom("PRPatrol_unconfigured_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {PRPatrol,
           repo: "owner/unconfigured-repo",
           workspace_id: unconfigured_ws.id,
           interval_ms: 60_000,
           name: name}
        )

      Req.Test.allow(@stub_name, self(), pid)
      :ok = PRPatrol.tick(name)

      [task] =
        Issue
        |> Ash.Query.filter(source_pr == "90")
        |> Ash.read!()

      assert task.status == :closed
      refute is_pid(Worker.whereis(task.id))

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(to_ref == "coordinator" and directive_ref == ^task.id)
        |> Ash.read!()

      assert [%{kind: :escalation}] = escalations
    end
  end

  describe "tick/1 — repeated dispatch failure backs off (bd-49ajyt)" do
    # A persistently-failing follow-up dispatch must escalate ONCE and then
    # back off — not re-file + re-dispatch + re-escalate every single tick
    # (the ~25-escalations-in-25-minutes firehose that motivated bd-49ajyt).
    test "two ticks with an unresolvable repo → ONE escalation, ONE task (not re-fired)",
         %{ws: _ws} do
      {:ok, unconfigured_ws} =
        Ash.create(Workspace, %{
          name: "pp-backoff-#{System.unique_integer([:positive])}",
          prefix: "ppb#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "backoff-repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/backoff-repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 95, "title" => "no repo path", "html_url" => "x"}])

          conn.request_path == "/repos/owner/backoff-repo/pulls/95/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/backoff-repo/pulls/95/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      name = String.to_atom("PRPatrol_backoff_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {PRPatrol,
           repo: "owner/backoff-repo",
           workspace_id: unconfigured_ws.id,
           interval_ms: 60_000,
           name: name}
        )

      Req.Test.allow(@stub_name, self(), pid)

      # Tick twice — the retry backoff window (>= interval_ms) has not elapsed
      # between them, so the second tick must NOT re-dispatch.
      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      tasks =
        Issue
        |> Ash.Query.filter(source_pr == "95")
        |> Ash.read!()

      assert length(tasks) == 1, "expected exactly one follow-up task, got #{length(tasks)}"

      escalations =
        Arbiter.Messages.Message
        |> Ash.Query.filter(
          to_ref == "coordinator" and workspace_id == ^unconfigured_ws.id and
            kind == :escalation
        )
        |> Ash.read!()

      assert length(escalations) == 1,
             "expected exactly one escalation, got #{length(escalations)}"
    end
  end

  describe "tick/1 — escalation persistence (bd-dtpjlf)" do
    # bd-dtpjlf: verus-ai-tools#13 failed to dispatch a follow-up 5 times in a
    # row; the first failure logged "...closing and escalating", every
    # subsequent one logged "(backing off, already escalated)" — but
    # `coordinator_inbox_peek` showed zero messages. The suppression was keyed
    # on having ATTEMPTED an escalation, not on one having persisted, so a
    # write that silently failed (or was swallowed by the old rescue/catch)
    # permanently blinded the coordinator to a repo that fails every follow-up
    # forever. Simulate that exact write failure via `escalate_send_fun` and
    # assert the next dispatch failure retries the escalation instead of
    # being suppressed.
    test "a failed escalation write is retried on the next dispatch failure, not suppressed",
         %{ws: _ws} do
      {:ok, unconfigured_ws} =
        Ash.create(Workspace, %{
          name: "pp-escalate-fail-#{System.unique_integer([:positive])}",
          prefix: "ppe#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "escalate-fail-repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/escalate-fail-repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 13, "title" => "verus-ai-tools#13", "html_url" => "x"}
            ])

          conn.request_path == "/repos/owner/escalate-fail-repo/pulls/13/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/escalate-fail-repo/pulls/13/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      escalate_send_fun = fn attrs ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          {:error, :simulated_write_failure}
        else
          Arbiter.Messages.Message.send_mail(attrs)
        end
      end

      name = String.to_atom("PRPatrol_escalate_fail_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {PRPatrol,
           repo: "owner/escalate-fail-repo",
           workspace_id: unconfigured_ws.id,
           interval_ms: 60_000,
           name: name,
           escalate_send_fun: escalate_send_fun}
        )

      Req.Test.allow(@stub_name, self(), pid)

      inbox = fn ->
        Arbiter.Messages.Message.inbox("coordinator", workspace_id: unconfigured_ws.id)
      end

      # Tick 1: dispatch fails, escalation write fails too (simulated) — the
      # bug's exact symptom is that nothing reaches the coordinator here.
      :ok = PRPatrol.tick(name)
      assert inbox.() == [], "escalation write failed — no message should have persisted"

      force_retry_now(pid, 13)

      # Tick 2: the backoff window has been rewound, so the follow-up dispatch
      # is retried and fails again. Because the FIRST escalation never
      # persisted, this must NOT be suppressed as "already escalated" — it
      # must retry.
      :ok = PRPatrol.tick(name)
      messages = inbox.()

      assert [message] = messages,
             "expected the retried escalation to persist exactly one message, got: #{inspect(messages)}"

      assert message.kind == :escalation
      assert message.subject =~ "PR #13"
      assert message.body =~ "escalate-fail-repo"
      assert message.body =~ "repo_not_found"

      force_retry_now(pid, 13)

      # Tick 3: dispatch fails again, but this time the PRIOR escalation DID
      # persist and the default re-escalate window (1 hour) hasn't elapsed —
      # so suppression should hold and no second message should appear.
      :ok = PRPatrol.tick(name)
      assert length(inbox.()) == 1, "a persisted escalation should suppress the next attempt"
    end

    # Acceptance: repeated consecutive failures must not stay silent forever —
    # they re-escalate on a bounded schedule. `re_escalate_after_ms` is the
    # test-only override of that schedule (production defaults to 1 hour).
    test "repeated consecutive failures re-escalate after the re-escalation window elapses",
         %{ws: _ws} do
      {:ok, unconfigured_ws} =
        Ash.create(Workspace, %{
          name: "pp-reescalate-#{System.unique_integer([:positive])}",
          prefix: "ppr#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "owner",
                "repo" => "reescalate-repo",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/reescalate-repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 14, "title" => "repeat failure", "html_url" => "x"}])

          conn.request_path == "/repos/owner/reescalate-repo/pulls/14/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/reescalate-repo/pulls/14/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      name = String.to_atom("PRPatrol_reescalate_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {PRPatrol,
           repo: "owner/reescalate-repo",
           workspace_id: unconfigured_ws.id,
           interval_ms: 60_000,
           re_escalate_after_ms: 1,
           name: name}
        )

      Req.Test.allow(@stub_name, self(), pid)

      inbox = fn ->
        Arbiter.Messages.Message
        |> Ash.Query.filter(
          to_ref == "coordinator" and workspace_id == ^unconfigured_ws.id and kind == :escalation
        )
        |> Ash.read!()
      end

      :ok = PRPatrol.tick(name)
      assert length(inbox.()) == 1, "first failure should escalate"

      force_retry_now(pid, 14)
      # `re_escalate_after_ms: 1` (1ms) has already elapsed by the time this
      # second tick runs.
      :ok = PRPatrol.tick(name)

      assert length(inbox.()) == 2,
             "a still-failing PR must re-escalate once the re-escalation window elapses, " <>
               "instead of staying silent forever"
    end
  end

  describe "tick/1 — zombie follow-up does not permanently block dedup (bd-bi5pn0)" do
    # Simulates a pre-existing zombie from the old bare-Worker.start bug (or
    # any future dispatch crash between registration and worktree
    # provisioning): a live, registered worker stuck :idle with no
    # meta.worktree_path. Left unfiltered, deduped?/2 would treat this as
    # "PR already handled" forever (lt-c9td4r) — the fix must ignore it.
    test "a zombie idle/no-worktree worker does not block re-dispatch on the same PR", %{ws: ws} do
      {:ok, zombie} =
        Ash.create(Issue, %{
          title: "zombie follow-up",
          tracker_type: :none,
          source_pr: "91",
          workspace_id: ws.id
        })

      {:ok, _pid} = Worker.start(task_id: zombie.id, repo: "owner/repo", workspace_id: ws.id)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 91, "title" => "zombie retry", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/91/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/91/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      tasks =
        Issue
        |> Ash.Query.filter(source_pr == "91")
        |> Ash.read!()

      assert length(tasks) == 2
    end

    # bd-6v2my2: every follow-up is now `:task` (not :feature/reviewable), so
    # `meta.worktree_path` is nil for every HEALTHY run too, not just a
    # zombie — the worktree_path check alone can no longer tell them apart.
    # Pin the same zombie-doesn't-block-dedup guarantee for a follow-up
    # registered with `issue_type: :task` in its meta, stuck `:idle`.
    test "a zombie idle `:task`-type follow-up does not block re-dispatch on the same PR",
         %{ws: ws} do
      {:ok, zombie} =
        Ash.create(Issue, %{
          title: "zombie task-type follow-up",
          tracker_type: :none,
          issue_type: :task,
          source_pr: "92",
          workspace_id: ws.id
        })

      {:ok, _pid} =
        Worker.start(
          task_id: zombie.id,
          repo: "owner/repo",
          workspace_id: ws.id,
          meta: %{issue_type: :task}
        )

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 92, "title" => "zombie task-type retry", "html_url" => "x"}
            ])

          conn.request_path == "/repos/owner/repo/pulls/92/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.request_path == "/repos/owner/repo/pulls/92/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      tasks =
        Issue
        |> Ash.Query.filter(source_pr == "92")
        |> Ash.read!()

      assert length(tasks) == 2
    end
  end

  # ---- helpers ----

  # A single GraphQL PullRequest node in the shape the batched query (bd-3byp1n)
  # fetches: reviews (→ changes_requested), reviewThreads (isResolved), and the
  # head commit's statusCheckRollup contexts (isRequired). All lists default
  # empty. `:cr` is a shorthand for one CHANGES_REQUESTED review.
  defp pr_node(opts) do
    reviews =
      cond do
        opts[:reviews] -> opts[:reviews]
        opts[:cr] -> [%{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "alice"}}]
        true -> []
      end

    %{
      "reviews" => %{"nodes" => reviews},
      "reviewThreads" => %{"nodes" => Keyword.get(opts, :threads, [])},
      "commits" => %{
        "nodes" => [
          %{
            "commit" => %{
              "statusCheckRollup" => %{
                "contexts" => %{"nodes" => Keyword.get(opts, :contexts, [])}
              }
            }
          }
        ]
      }
    }
  end

  # Build the `%{"data" => ...}` batched-signals response by MIRRORING the
  # aliased GraphQL query the adapter POSTed: walk its lines, map each `r<j>:
  # repository(` block and the `p<k>: pullRequest(number: N)` aliases inside it,
  # and nest the per-number node from `by_number` under `data[ralias][palias]`.
  # A number absent from `by_number` yields a `null` node (partial-failure path).
  # Decoupled from the adapter's exact alias scheme.
  defp batch_data_from_query(query, by_number) do
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
            {put_in(data, [cur, palias], node), cur}

          true ->
            {data, cur}
        end
      end)

    %{"data" => data}
  end

  # A full stub for a PRPatrol sweep that batches its signals (bd-3byp1n):
  #   * GET  /repos/<repo>/pulls   → the open-PR list from `pulls`
  #   * POST /graphql              → the batched signals response, mirrored from
  #                                  the aliased query and `nodes` (number → node)
  # `opts`: repo (default "owner/repo"), pulls (list payload), nodes (map),
  # graphql_counter (optional :counters ref bumped once per /graphql POST).
  defp signals_stub(opts) do
    repo = Keyword.get(opts, :repo, "owner/repo")
    pulls = Keyword.get(opts, :pulls, [])
    nodes = Keyword.get(opts, :nodes, %{})
    counter = Keyword.get(opts, :graphql_counter)

    fn conn ->
      cond do
        conn.request_path == "/repos/#{repo}/pulls" and conn.method == "GET" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(pulls)

        conn.method == "POST" and conn.request_path == "/graphql" ->
          if counter, do: :counters.add(counter, 1, 1)
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          query = Jason.decode!(body)["query"]

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(batch_data_from_query(query, nodes))

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end
  end

  # A `/pulls` payload entry.
  defp pull(number, opts \\ []) do
    %{
      "number" => number,
      "title" => Keyword.get(opts, :title, "t#{number}"),
      "html_url" => Keyword.get(opts, :html_url, "https://gh/pr/#{number}")
    }
    |> then(fn m ->
      case Keyword.get(opts, :author) do
        nil -> m
        login -> Map.put(m, "user", %{"login" => login})
      end
    end)
  end

  # Stub the `/pulls` list (carrying `user.login` so PRPatrol can resolve the MR
  # author) plus a batched CHANGES_REQUESTED signal for `number`, so the only
  # variable under test is the author gate.
  defp pulls_stub(number, author_login) do
    stub(
      signals_stub(
        pulls: [pull(number, author: author_login)],
        nodes: %{number => pr_node(cr: true)}
      )
    )
  end

  # PRPatrol follow-ups link their source PR via `source_pr` (and carry
  # `tracker_type: :none`, so they never sync lifecycle onto a merged PR —
  # bd-ci2jl2). Select them by the presence of `source_pr`.
  defp tasks_for_repo do
    Issue
    |> Ash.Query.filter(not is_nil(source_pr))
    |> Ash.read!()
  end

  # ---- lazy-start lifecycle (bd-7tr11p) ----

  # Create an open fleet-authored PR task: a task whose `pr_ref` was stamped by
  # the MergeQueue when it opened the PR. `pr_ref` is not create-accepted, so
  # set it via :update exactly as the MergeQueue does.
  defp create_pr_task!(ws, pr_ref) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "authored-#{System.unique_integer([:positive])}",
        description: "d",
        issue_type: :feature,
        tracker_type: :none,
        workspace_id: ws.id
      })

    {:ok, task} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)
    task
  end

  # Start a PRPatrol directly (not under start_supervised), so a self-initiated
  # :normal stop is observable via a monitor without the ExUnit supervisor's
  # restart getting in the way.
  defp start_unsupervised(ws, repo) do
    name = String.to_atom("PRPatrol_lazy_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      PRPatrol.start_link(
        repo: repo,
        workspace_id: ws.id,
        interval_ms: 60_000,
        name: name
      )

    Req.Test.allow(@stub_name, self(), pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
    {pid, name}
  end

  describe "has_open_authored_pr?/2 — lazy-start DB gate (bd-7tr11p)" do
    test "true for a repo with an open fleet-authored PR task (bare ref)", %{ws: ws} do
      create_pr_task!(ws, "#7")
      assert PRPatrol.has_open_authored_pr?(ws.id, "owner/repo")
    end

    test "false with no pr_ref task at all", %{ws: ws} do
      refute PRPatrol.has_open_authored_pr?(ws.id, "owner/repo")
    end

    test "false once the only pr_ref task is closed", %{ws: ws} do
      task = create_pr_task!(ws, "#7")
      {:ok, _} = Ash.update(task, %{}, action: :close)
      refute PRPatrol.has_open_authored_pr?(ws.id, "owner/repo")
    end

    test "a qualified pr_ref scopes to its own repo (multi-repo shape)", %{ws: ws} do
      create_pr_task!(ws, "octo/alpha#1")
      assert PRPatrol.has_open_authored_pr?(ws.id, "octo/alpha")
      refute PRPatrol.has_open_authored_pr?(ws.id, "octo/beta")
    end
  end

  describe "scheduled tick self-termination (bd-7tr11p)" do
    test "a scheduled tick makes zero forge calls and stops when nothing is watched",
         %{ws: ws} do
      test_pid = self()

      # If the patrol touches GitHub, this stub reports it — proving the guard
      # fired BEFORE any forge call (near-zero background consumption).
      stub(fn conn ->
        send(test_pid, {:github_called, conn.request_path})
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {pid, _name} = start_unsupervised(ws, "owner/repo")
      ref = Process.monitor(pid)

      send(pid, :tick)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_receive {:github_called, _}, 100
    end

    test "a scheduled tick proceeds (and the patrol survives) when a fleet PR is open",
         %{ws: ws} do
      create_pr_task!(ws, "#7")
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:github_called, conn.request_path})
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      {pid, name} = start_unsupervised(ws, "owner/repo")

      send(pid, :tick)

      # It hit list_open (watched work present) and is still alive afterward.
      assert_receive {:github_called, "/repos/owner/repo/pulls"}, 2_000
      assert Process.alive?(pid)
      assert PRPatrol.state(name).ticks >= 1
    end
  end

  describe ":recheck (prompt stop on last-item close, bd-7tr11p)" do
    test ":recheck stops the patrol when its last watched item has closed", %{ws: ws} do
      task = create_pr_task!(ws, "#7")
      {pid, _name} = start_unsupervised(ws, "owner/repo")
      ref = Process.monitor(pid)

      {:ok, _} = Ash.update(task, %{}, action: :close)
      send(pid, :recheck)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test ":recheck keeps the patrol alive while a watched item remains", %{ws: ws} do
      create_pr_task!(ws, "#7")
      {pid, _name} = start_unsupervised(ws, "owner/repo")

      send(pid, :recheck)
      # Give the message time to be processed, then confirm still alive.
      _ = PRPatrol.state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "child_spec restart policy (bd-7tr11p)" do
    test "is :transient so a :normal self-stop is not restarted" do
      assert PRPatrol.child_spec([]).restart == :transient
    end
  end
end
