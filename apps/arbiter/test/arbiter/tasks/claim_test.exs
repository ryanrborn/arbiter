defmodule Arbiter.Tasks.ClaimTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config, as: GHConfig
  alias Arbiter.Trackers.Jira.Config, as: JiraConfig
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  @viewer "test-worker"
  @env_var "ARBITER_CLAIM_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "claim-test-token")

    {:ok, github_ws} =
      Ash.create(Workspace, %{
        name: "claim-gh",
        prefix: "cgh",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    {:ok, none_ws} =
      Ash.create(Workspace, %{
        name: "claim-none",
        prefix: "cn"
      })

    {:ok, jira_ws} =
      Ash.create(Workspace, %{
        name: "claim-jira",
        prefix: "cj",
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "test.atlassian.net",
              "project_key" => "TEST",
              "credentials_ref" => "env:#{@env_var}",
              "email" => "tester@example.com"
            }
          }
        }
      })

    {:ok, sc_ws} =
      Ash.create(Workspace, %{
        name: "claim-sc",
        prefix: "cs",
        config: %{
          "tracker" => %{
            "type" => "shortcut",
            "config" => %{
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    on_exit(fn ->
      GHConfig.clear()
      JiraConfig.clear()
      SCConfig.clear()
      System.delete_env(@env_var)
    end)

    {:ok, github_ws: github_ws, none_ws: none_ws, jira_ws: jira_ws, sc_ws: sc_ws}
  end

  defp stub_gh(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)
  defp stub_jira(fun), do: Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fun)
  defp stub_sc(fun), do: Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fun)

  defp issue_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 43,
        "title" => "Wire up the thing",
        "body" => "Mirror me into a task.",
        "state" => "open",
        "html_url" => "https://github.com/ryanrborn/arbiter/issues/43",
        "assignees" => [%{"login" => @viewer}]
      },
      overrides
    )
  end

  @jira_account_id "jira-account-abc123"
  @sc_member_id "sc-member-uuid-456"

  defp jira_issue_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "TEST-43",
        "fields" => %{
          "summary" => "Wire up the thing",
          "description" => nil,
          "assignee" => %{"accountId" => @jira_account_id},
          "status" => %{
            "name" => "In Progress",
            "statusCategory" => %{"key" => "indeterminate"}
          }
        }
      },
      overrides
    )
  end

  defp sc_story_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 43,
        "name" => "Wire up the thing",
        "description" => "Mirror me into a task.",
        "app_url" => "https://app.shortcut.com/story/43",
        "owner_ids" => [@sc_member_id],
        "completed" => false,
        "started" => false
      },
      overrides
    )
  end

  describe "claim/3 — GitHub" do
    test "creates a task mirrored from the issue when assigned to viewer", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, %Issue{} = task} = Claim.claim(ws, "43")
      assert task.workspace_id == ws.id
      assert task.tracker_type == :github
      assert task.tracker_ref == "43"
      assert task.title == "Wire up the thing"
      assert task.description == "Mirror me into a task."
      assert task.status == :open
    end

    test "is idempotent — returns existing task instead of duplicating", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"GET", _} ->
            Req.Test.json(conn, issue_payload())

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, first} = Claim.claim(ws, "43")
      assert {:ok, :existing, second} = Claim.claim(ws, "43")
      assert first.id == second.id
    end

    test "refuses when the issue isn't assigned to the viewer", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", _} ->
            Req.Test.json(conn, issue_payload(%{"assignees" => [%{"login" => "someone-else"}]}))
        end
      end)

      assert {:error, {:not_assigned, @viewer}} = Claim.claim(ws, "43")
    end

    test "force: true bypasses the assignment check", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"GET", _} ->
            Req.Test.json(conn, issue_payload(%{"assignees" => []}))

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, _task} = Claim.claim(ws, "43", force: true)
    end

    # bd-6xaaam: force: true must never silently reassign a colleague's ticket.
    test "force: true is refused when the issue is assigned to someone else", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", _} ->
            Req.Test.json(
              conn,
              issue_payload(%{"assignees" => [%{"login" => "alec-kustanovich"}]})
            )
        end
      end)

      assert {:error, {:not_assigned, @viewer}} = Claim.claim(ws, "43", force: true)
    end

    test "accepts decorated refs like '#43' and 'gh-43' and a full URL", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"GET", _} ->
            Req.Test.json(conn, issue_payload())

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, b1} = Claim.claim(ws, "#43")
      assert b1.tracker_ref == "43"

      assert {:ok, :existing, _} = Claim.claim(ws, "gh-43")

      assert {:ok, :existing, _} =
               Claim.claim(ws, "https://github.com/ryanrborn/arbiter/issues/43")
    end

    test "returns invalid_ref for garbage", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} -> Req.Test.json(conn, %{"login" => @viewer})
        end
      end)

      assert {:error, {:invalid_ref, "not-a-number"}} = Claim.claim(ws, "not-a-number")
    end

    test "returns tracker_not_supported when the workspace tracker is none", %{none_ws: ws} do
      assert {:error, :tracker_not_supported} = Claim.claim(ws, "43")
    end

    test "refuses when another Arbiter installation has already claimed the issue",
         %{github_ws: ws} do
      prior_body =
        "Claimed as other-bd-abc123 by other-fleet (other). Arbiter installation: other-host."

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [%{"body" => prior_body, "user" => %{"login" => "other-bot"}}])
        end
      end)

      assert {:error, {:already_claimed, ^prior_body}} = Claim.claim(ws, "43")
    end

    test "force: true bypasses the prior-claim check", %{github_ws: ws} do
      prior_body =
        "Claimed as other-bd-abc123 by other-fleet (other). Arbiter installation: other-host."

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [%{"body" => prior_body, "user" => %{"login" => "other-bot"}}])

          {"GET", _} ->
            Req.Test.json(conn, issue_payload())

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, _task} = Claim.claim(ws, "43", force: true)
    end

    test "ownership comment is posted when a new task is created", %{github_ws: ws} do
      test_pid = self()

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:comment_posted, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "43")

      assert_receive {:comment_posted, %{"body" => comment_body}}
      assert String.contains?(comment_body, task.id)
      assert String.contains?(comment_body, ws.name)
      assert String.contains?(comment_body, ws.prefix)
      assert String.contains?(comment_body, "Arbiter installation:")
    end

    test "ownership comment is NOT posted for an already-existing task", %{github_ws: ws} do
      test_pid = self()

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"GET", _} ->
            Req.Test.json(conn, issue_payload())

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            send(test_pid, :comment_posted)
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, _} = Claim.claim(ws, "43")
      assert_receive :comment_posted

      assert {:ok, :existing, _} = Claim.claim(ws, "43")
      refute_receive :comment_posted
    end

    test "comment-fetch failure does not abort a claim", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "server error"})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, _task} = Claim.claim(ws, "43")
    end
  end

  describe "claim/3 — Jira" do
    test "creates a task when the issue is assigned to the current user", %{jira_ws: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            Req.Test.json(conn, jira_issue_payload())

          {"GET", "/rest/api/3/issue/TEST-43/comment"} ->
            Req.Test.json(conn, %{"comments" => []})

          {"POST", "/rest/api/3/issue/TEST-43/comment"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/rest/api/3/issue/TEST-43/assignee"} ->
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, %Issue{} = task} = Claim.claim(ws, "TEST-43")
      assert task.tracker_type == :jira
      assert task.tracker_ref == "TEST-43"
      assert task.title == "Wire up the thing"
    end

    test "refuses when the issue is not assigned to the current user", %{jira_ws: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            other = %{"accountId" => "someone-else-id"}

            Req.Test.json(
              conn,
              jira_issue_payload(%{
                "fields" => %{
                  "assignee" => other,
                  "summary" => "Wire up the thing",
                  "status" => %{"statusCategory" => %{"key" => "new"}}
                }
              })
            )
        end
      end)

      assert {:error, {:not_assigned, @jira_account_id}} = Claim.claim(ws, "TEST-43")
    end

    test "is idempotent for Jira claims", %{jira_ws: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", _} ->
            Req.Test.json(conn, jira_issue_payload())

          {"POST", "/rest/api/3/issue/TEST-43/comment"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/rest/api/3/issue/TEST-43/assignee"} ->
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, first} = Claim.claim(ws, "TEST-43")
      assert {:ok, :existing, second} = Claim.claim(ws, "TEST-43")
      assert first.id == second.id
    end
  end

  describe "claim/3 — Shortcut" do
    test "creates a task when the story is owned by the current member", %{sc_ws: ws} do
      stub_sc(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => @sc_member_id})

          {"GET", "/api/v3/stories/43"} ->
            Req.Test.json(conn, sc_story_payload())

          {"GET", "/api/v3/stories/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/api/v3/stories/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/api/v3/stories/43"} ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, %Issue{} = task} = Claim.claim(ws, "43")
      assert task.tracker_type == :shortcut
      assert task.tracker_ref == "43"
      assert task.title == "Wire up the thing"
    end

    test "refuses when the story is not owned by the current member", %{sc_ws: ws} do
      stub_sc(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => @sc_member_id})

          {"GET", "/api/v3/stories/43"} ->
            Req.Test.json(conn, sc_story_payload(%{"owner_ids" => ["different-member-id"]}))
        end
      end)

      assert {:error, {:not_assigned, @sc_member_id}} = Claim.claim(ws, "43")
    end
  end

  describe "plan/1 and apply_plan/2 — GitHub" do
    test "creates tasks for assigned-open issues with no task, and closes orphan tasks",
         %{github_ws: ws} do
      {:ok, _existing} =
        Ash.create(Issue, %{
          title: "Stale claim for 44",
          tracker_type: :github,
          tracker_ref: "44",
          workspace_id: ws.id
        })

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [
              issue_payload(%{"number" => 43, "title" => "Issue 43"})
            ])

          {"GET", "/repos/ryanrborn/arbiter/issues/44"} ->
            Req.Test.json(
              conn,
              issue_payload(%{
                "number" => 44,
                "title" => "Issue 44",
                "assignees" => [%{"login" => "someone-else"}]
              })
            )

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 43, "title" => "Issue 43"}))

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:create, "43", %{title: "Issue 43"}}, {:close, _task_id, _reason}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert length(results) == 2
      assert Enum.any?(results, &match?({:created, _}, &1))
      assert Enum.any?(results, &match?({:closed, _}, &1))

      tasks =
        Ash.read!(Issue)
        |> Enum.filter(&(&1.workspace_id == ws.id))

      task_43 = Enum.find(tasks, &(&1.tracker_ref == "43"))
      task_44 = Enum.find(tasks, &(&1.tracker_ref == "44"))

      assert task_43.status == :open
      assert task_44.status == :closed
    end

    test "empty plan when tracker doesn't support claim", %{none_ws: ws} do
      assert {:ok, []} = Claim.plan(ws)
    end

    test "reports drift for a task closed locally whose tracker issue is still open (bd-2wilou)",
         %{github_ws: ws} do
      {:ok, drifted_task} =
        Ash.create(Issue, %{
          title: "Closed locally, issue still open",
          tracker_type: :github,
          tracker_ref: "45",
          workspace_id: ws.id
        })

      # bd-bsco7f restores this to its original **no-`pr_ref`** shape. bd-83ojwi
      # had to bolt a `pr_ref` on to keep it green; that edit was the blind spot
      # made concrete. The close below asks to propagate (`close_upstream: true`)
      # and the stubbed tracker never actually closes — a failed propagation, no
      # PR anywhere in sight. That is the bd-2wilou case verbatim.
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {method, "/repos/ryanrborn/arbiter/issues/45"} when method in ["GET", "PATCH"] ->
            # The PATCH is accepted but never takes: the issue stays open.
            Req.Test.json(
              conn,
              issue_payload(%{"number" => 45, "title" => "Issue 45", "state" => "open"})
            )
        end
      end)

      {:ok, drifted_task} = Ash.update(drifted_task, %{close_upstream: true}, action: :close)
      refute drifted_task.pr_ref

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:drift, task_id, reason}] = plan
      assert task_id == drifted_task.id
      assert reason =~ "still open"

      assert {:ok, [{:drifted, reported_task}]} = Claim.apply_plan(ws, plan)
      assert reported_task.id == drifted_task.id

      {:ok, reloaded} = Ash.get(Issue, drifted_task.id)
      assert reloaded.status == :closed
    end

    test "no drift reported when the closed task's tracker issue is also closed",
         %{github_ws: ws} do
      {:ok, closed_task} =
        Ash.create(Issue, %{
          title: "Closed locally and upstream",
          tracker_type: :github,
          tracker_ref: "46",
          workspace_id: ws.id
        })

      {:ok, _closed_task} = Ash.update(closed_task, %{close_upstream: false}, action: :close)

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/46"} ->
            Req.Test.json(
              conn,
              issue_payload(%{"number" => 46, "title" => "Issue 46", "state" => "closed"})
            )
        end
      end)

      assert {:ok, []} = Claim.plan(ws)
    end
  end

  describe "plan/1 — close safety and drift policy (bd-83ojwi)" do
    # Helper: an open local task linked to `ref`, absent from list_open.
    defp open_task(ws, ref, attrs \\ %{}) do
      Ash.create!(
        Issue,
        Map.merge(
          %{
            title: "Local task for #{ref}",
            tracker_type: :github,
            tracker_ref: ref,
            workspace_id: ws.id
          },
          attrs
        )
      )
    end

    # `pr_ref` is set by the merger, not at create time, so it goes on via a
    # follow-up update — same order as production.
    defp closed_task(ws, ref, attrs) do
      {pr_ref, create_attrs} = Map.pop(attrs, :pr_ref)

      ws
      |> open_task(ref, create_attrs)
      |> then(fn task ->
        if pr_ref, do: Ash.update!(task, %{pr_ref: pr_ref}), else: task
      end)
      |> Ash.update!(%{close_upstream: false}, action: :close)
    end

    test "an open-but-unassigned tracker issue does NOT propose a close", %{github_ws: ws} do
      _task = open_task(ws, "60", %{issue_type: :decision})

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/60"} ->
            Req.Test.json(
              conn,
              issue_payload(%{"number" => 60, "state" => "open", "assignees" => []})
            )
        end
      end)

      assert {:ok, []} = Claim.plan(ws)
    end

    test "a tracker issue that can't be fetched does NOT propose a close", %{github_ws: ws} do
      _task = open_task(ws, "61")

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/61"} ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
        end
      end)

      assert {:ok, []} = Claim.plan(ws)
    end

    test "an issue genuinely closed upstream still proposes a close", %{github_ws: ws} do
      task = open_task(ws, "62")

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/62"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 62, "state" => "closed"}))
        end
      end)

      assert {:ok, [{:close, task_id, reason}]} = Claim.plan(ws)
      assert task_id == task.id
      assert reason =~ "closed"
    end

    test "an issue reassigned to someone else still proposes a close", %{github_ws: ws} do
      task = open_task(ws, "63")

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/63"} ->
            Req.Test.json(
              conn,
              issue_payload(%{
                "number" => 63,
                "state" => "open",
                "assignees" => [%{"login" => "someone-else"}]
              })
            )
        end
      end)

      assert {:ok, [{:close, task_id, reason}]} = Claim.plan(ws)
      assert task_id == task.id
      assert reason =~ "reassigned to someone-else"
    end

    test "a closed `task`-type task whose tracker issue is still open is NOT drift",
         %{github_ws: ws} do
      # Even with a PR: research work can ship a diff and still leave the
      # underlying ticket open.
      _task = closed_task(ws, "64", %{issue_type: :task, pr_ref: "900"})

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/64"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 64, "state" => "open"}))
        end
      end)

      assert {:ok, []} = Claim.plan(ws)
    end

    test "a closed `bug`/`feature` task that shipped a PR, tracker issue still open, IS drift",
         %{github_ws: ws} do
      bug = closed_task(ws, "65", %{issue_type: :bug, pr_ref: "901"})
      feature = closed_task(ws, "66", %{issue_type: :feature, pr_ref: "902"})

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/65"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 65, "state" => "open"}))

          {"GET", "/repos/ryanrborn/arbiter/issues/66"} ->
            Req.Test.json(conn, issue_payload(%{"number" => 66, "state" => "open"}))
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      drifted = for {:drift, id, _reason} <- plan, do: id
      assert Enum.sort(drifted) == Enum.sort([bug.id, feature.id])
    end

    # The live vs-9y1ipo / vs-bdix5z case: filed as `bug`, closed as a
    # completed investigation with findings in `notes` and no PR. The bug is
    # still unfixed, so the ticket is *supposed* to stay open.
    test "a closed `bug` with no PR (findings-only close) is NOT drift", %{github_ws: ws} do
      _no_pr = closed_task(ws, "67", %{issue_type: :bug})
      _blank_pr = closed_task(ws, "68", %{issue_type: :bug, pr_ref: "  "})

      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {"GET", "/repos/ryanrborn/arbiter/issues/" <> n} ->
            Req.Test.json(
              conn,
              issue_payload(%{"number" => String.to_integer(n), "state" => "open"})
            )
        end
      end)

      assert {:ok, []} = Claim.plan(ws)
    end
  end

  describe "plan/1 — drift gates on the recorded close intent (bd-bsco7f)" do
    # One stub for the whole close→plan round trip: the close-time PATCH is
    # accepted but never takes (the issue is still "open" on every read), which
    # is the failed upstream propagation this drift check exists to catch.
    defp stub_forever_open_issues do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [])

          {_method, "/repos/ryanrborn/arbiter/issues/" <> n} ->
            Req.Test.json(
              conn,
              issue_payload(%{"number" => String.to_integer(n), "state" => "open"})
            )
        end
      end)
    end

    defp closed_upstream_task(ws, ref, attrs) do
      ws
      |> open_task(ref, attrs)
      |> Ash.update!(%{close_upstream: true}, action: :close)
    end

    # Simulate a row closed before `close_upstream_expected` existed: the column
    # is NULL, so the gate has nothing but the legacy `pr_ref` proxy to go on.
    defp forget_close_intent(task) do
      Arbiter.Repo.query!("UPDATE issues SET close_upstream_expected = NULL WHERE id = $1", [
        task.id
      ])

      task
    end

    test "a closed `bug` with NO pr_ref whose close was meant to propagate IS drift",
         %{github_ws: ws} do
      stub_forever_open_issues()
      bug = closed_upstream_task(ws, "70", %{issue_type: :bug})
      chore = closed_upstream_task(ws, "71", %{issue_type: :chore})

      refute bug.pr_ref
      refute chore.pr_ref

      assert {:ok, plan} = Claim.plan(ws)
      drifted = for {:drift, id, _reason} <- plan, do: id
      assert Enum.sort(drifted) == Enum.sort([bug.id, chore.id])
    end

    test "a close that explicitly opted out of propagating is NOT drift", %{github_ws: ws} do
      stub_forever_open_issues()
      _investigation = closed_task(ws, "72", %{issue_type: :bug})

      assert {:ok, []} = Claim.plan(ws)
    end

    test "a `task`-type close stays exempt even when it was meant to propagate",
         %{github_ws: ws} do
      stub_forever_open_issues()
      _research = closed_upstream_task(ws, "73", %{issue_type: :task})

      assert {:ok, []} = Claim.plan(ws)
    end

    test "a review-only close is NOT drift — it never owned the ticket", %{github_ws: ws} do
      stub_forever_open_issues()
      _borrowed = closed_upstream_task(ws, "74", %{issue_type: :bug, review_only: true})

      assert {:ok, []} = Claim.plan(ws)
    end

    test "a legacy close with no recorded intent falls back to the pr_ref proxy",
         %{github_ws: ws} do
      stub_forever_open_issues()

      landed =
        ws
        |> open_task("75", %{issue_type: :bug})
        |> Ash.update!(%{pr_ref: "975"})
        |> Ash.update!(%{close_upstream: true}, action: :close)
        |> forget_close_intent()

      _findings_only =
        ws
        |> closed_upstream_task("76", %{issue_type: :bug})
        |> forget_close_intent()

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:drift, task_id, _reason}] = plan
      assert task_id == landed.id
    end
  end

  describe "plan/1 and apply_plan/2 — Jira" do
    test "creates tasks for assigned open Jira issues with no task", %{jira_ws: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"POST", "/rest/api/3/search/jql"} ->
            Req.Test.json(conn, %{
              "issues" => [jira_issue_payload()]
            })

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            Req.Test.json(conn, jira_issue_payload())

          {"GET", "/rest/api/3/issue/TEST-43/comment"} ->
            Req.Test.json(conn, %{"comments" => []})

          {"POST", "/rest/api/3/issue/TEST-43/comment"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/rest/api/3/issue/TEST-43/assignee"} ->
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:create, "TEST-43", _}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert [{:created, task}] = results
      assert task.tracker_type == :jira
      assert task.tracker_ref == "TEST-43"
    end
  end

  describe "claim/3 — priority and difficulty wiring" do
    test "GitHub: priority label populates task.priority; 0 is the highest priority",
         %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(%{"labels" => [%{"name" => "priority: 0"}]}))

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "43")
      assert task.priority == 0
    end

    test "GitHub: no priority label preserves schema default (priority 2)", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(%{"labels" => [%{"name" => "bug"}]}))

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "43")
      assert task.priority == 2
    end

    test "GitHub: difficulty label populates task.difficulty; 0 is trivial", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(
              conn,
              issue_payload(%{
                "labels" => [%{"name" => "priority: 1"}, %{"name" => "difficulty: 0"}]
              })
            )

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "43")
      assert task.priority == 1
      assert task.difficulty == 0
    end

    test "GitHub: no difficulty label leaves task.difficulty nil", %{github_ws: ws} do
      stub_gh(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload())

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "43")
      assert is_nil(task.difficulty)
    end

    test "Jira: Highest priority maps to P0 — priority 0 is highest", %{jira_ws: ws} do
      payload =
        jira_issue_payload(%{
          "fields" => %{
            "summary" => "Wire up the thing",
            "assignee" => %{"accountId" => @jira_account_id},
            "status" => %{"statusCategory" => %{"key" => "new"}},
            "priority" => %{"name" => "Highest"}
          }
        })

      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            Req.Test.json(conn, payload)

          {"GET", "/rest/api/3/issue/TEST-43/comment"} ->
            Req.Test.json(conn, %{"comments" => []})

          {"POST", "/rest/api/3/issue/TEST-43/comment"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/rest/api/3/issue/TEST-43/assignee"} ->
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, task} = Claim.claim(ws, "TEST-43")
      assert task.priority == 0
    end
  end

  describe "plan/1 and apply_plan/2 — Shortcut" do
    test "creates tasks for assigned open Shortcut stories with no task", %{sc_ws: ws} do
      stub_sc(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => @sc_member_id})

          {"POST", "/api/v3/stories/search"} ->
            Req.Test.json(conn, [sc_story_payload()])

          {"GET", "/api/v3/stories/43"} ->
            Req.Test.json(conn, sc_story_payload())

          {"GET", "/api/v3/stories/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", "/api/v3/stories/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"PUT", "/api/v3/stories/43"} ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:create, "43", _}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert [{:created, task}] = results
      assert task.tracker_type == :shortcut
      assert task.tracker_ref == "43"
    end
  end
end
