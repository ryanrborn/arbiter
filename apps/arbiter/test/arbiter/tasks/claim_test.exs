defmodule Arbiter.Tasks.ClaimTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config, as: GHConfig
  alias Arbiter.Trackers.Jira.Config, as: JiraConfig
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  @viewer "test-acolyte"
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
