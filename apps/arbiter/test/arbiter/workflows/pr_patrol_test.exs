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

    pid =
      start_supervised!(
        {PRPatrol,
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
      # tracker_type is :none so dispatch never tries to transition the merged
      # PR; the source PR is linked via source_pr instead (bd-ci2jl2). The
      # follow-up is a reviewable type so dispatch provisions a fresh worktree.
      assert task.tracker_type == :none
      assert task.source_pr == "42"
      assert task.issue_type == :feature
      assert task.title =~ "PR #42"
      assert task.workspace_id == ws.id

      # Worker is registered for this task
      assert is_pid(Worker.whereis(task.id))
    end

    test "COMMENTED review with an unresolved review thread → 1 task created, worker spawned",
         %{ws: ws} do
      # The Copilot-on-#3609 case: the review is COMMENTED (not CHANGES_REQUESTED),
      # so changes_requested? is false — but it left an inline comment that lives
      # in an unresolved review thread, which the GraphQL primitive surfaces.
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 50, "title" => "commented only", "html_url" => "https://gh/pr/50"}
            ])

          conn.request_path == "/repos/owner/repo/pulls/50/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "COMMENTED", "user" => %{"login" => "copilot"}}])

          conn.request_path == "/repos/owner/repo/pulls/50/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{
                    "reviewThreads" => %{
                      "nodes" => [
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
                    }
                  }
                }
              }
            })

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      [task] = tasks_for_repo()
      assert task.source_pr == "50"
      assert task.title =~ "PR #50"
      assert task.description =~ "unresolved review thread"
      assert is_pid(Worker.whereis(task.id))
    end

    test "COMMENTED review with all threads resolved → no task", %{ws: ws} do
      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"number" => 51, "title" => "resolved", "html_url" => "x"}])

          conn.request_path == "/repos/owner/repo/pulls/51/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "COMMENTED"}])

          conn.request_path == "/repos/owner/repo/pulls/51/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "POST" and conn.request_path == "/graphql" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "data" => %{
                "repository" => %{
                  "pullRequest" => %{
                    "reviewThreads" => %{
                      "nodes" => [%{"id" => "RT_1", "isResolved" => true}]
                    }
                  }
                }
              }
            })

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_patrol(ws)
      assert :ok = PRPatrol.tick(name)
      assert tasks_for_repo() == []
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

  describe "tick/1 — multi-repo workspace (no repo in config)" do
    test "patrol with explicit repo works when workspace config omits repo field", %{ws: _ws} do
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

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/owner/explicit-repo/pulls" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{
                "number" => 60,
                "title" => "multi-repo PR",
                "html_url" => "https://gh/pr/60"
              }
            ])

          conn.request_path == "/repos/owner/explicit-repo/pulls/60/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}}
            ])

          conn.request_path == "/repos/owner/explicit-repo/pulls/60/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      name = String.to_atom("PRPatrol_multirepo_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {PRPatrol,
           [
             repo: "owner/explicit-repo",
             workspace_id: multi_ws.id,
             interval_ms: 60_000,
             name: name
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

  # ---- helpers ----

  # Stub the `/pulls` list (carrying `user.login` so PRPatrol can resolve the
  # MR author) plus a CHANGES_REQUESTED review for `number`, so the only
  # variable under test is the author gate.
  defp pulls_stub(number, author_login) do
    stub(fn conn ->
      cond do
        conn.request_path == "/repos/owner/repo/pulls" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json([
            %{
              "number" => number,
              "title" => "t#{number}",
              "html_url" => "https://gh/pr/#{number}",
              "user" => %{"login" => author_login}
            }
          ])

        conn.request_path == "/repos/owner/repo/pulls/#{number}/reviews" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

        conn.request_path == "/repos/owner/repo/pulls/#{number}/comments" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)
  end

  # PRPatrol follow-ups link their source PR via `source_pr` (and carry
  # `tracker_type: :none`, so they never sync lifecycle onto a merged PR —
  # bd-ci2jl2). Select them by the presence of `source_pr`.
  defp tasks_for_repo do
    Issue
    |> Ash.Query.filter(not is_nil(source_pr))
    |> Ash.read!()
  end
end
