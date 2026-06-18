defmodule Arbiter.Beads.ClaimTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Claim, Issue, Workspace}
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
        "body" => "Mirror me into a bead.",
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
        "description" => "Mirror me into a bead.",
        "app_url" => "https://app.shortcut.com/story/43",
        "owner_ids" => [@sc_member_id],
        "completed" => false,
        "started" => false
      },
      overrides
    )
  end

  describe "claim/3 — GitHub" do
    test "creates a bead mirrored from the issue when assigned to viewer", %{github_ws: ws} do
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

      assert {:ok, :created, %Issue{} = bead} = Claim.claim(ws, "43")
      assert bead.workspace_id == ws.id
      assert bead.tracker_type == :github
      assert bead.tracker_ref == "43"
      assert bead.title == "Wire up the thing"
      assert bead.description == "Mirror me into a bead."
      assert bead.status == :open
    end

    test "is idempotent — returns existing bead instead of duplicating", %{github_ws: ws} do
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

      assert {:ok, :created, _bead} = Claim.claim(ws, "43", force: true)
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

      assert {:ok, :created, _bead} = Claim.claim(ws, "43", force: true)
    end

    test "ownership comment is posted when a new bead is created", %{github_ws: ws} do
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

      assert {:ok, :created, bead} = Claim.claim(ws, "43")

      assert_receive {:comment_posted, %{"body" => comment_body}}
      assert String.contains?(comment_body, bead.id)
      assert String.contains?(comment_body, ws.name)
      assert String.contains?(comment_body, ws.prefix)
      assert String.contains?(comment_body, "Arbiter installation:")
    end

    test "ownership comment is NOT posted for an already-existing bead", %{github_ws: ws} do
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

      assert {:ok, :created, _bead} = Claim.claim(ws, "43")
    end
  end

  describe "claim/3 — Jira" do
    test "creates a bead when the issue is assigned to the current user", %{jira_ws: ws} do
      stub_jira(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/myself"} ->
            Req.Test.json(conn, %{"accountId" => @jira_account_id})

          {"GET", "/rest/api/3/issue/TEST-43"} ->
            Req.Test.json(conn, jira_issue_payload())
        end
      end)

      assert {:ok, :created, %Issue{} = bead} = Claim.claim(ws, "TEST-43")
      assert bead.tracker_type == :jira
      assert bead.tracker_ref == "TEST-43"
      assert bead.title == "Wire up the thing"
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
          {"GET", "/rest/api/3/myself"} -> Req.Test.json(conn, %{"accountId" => @jira_account_id})
          {"GET", _} -> Req.Test.json(conn, jira_issue_payload())
        end
      end)

      assert {:ok, :created, first} = Claim.claim(ws, "TEST-43")
      assert {:ok, :existing, second} = Claim.claim(ws, "TEST-43")
      assert first.id == second.id
    end
  end

  describe "claim/3 — Shortcut" do
    test "creates a bead when the story is owned by the current member", %{sc_ws: ws} do
      stub_sc(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => @sc_member_id})

          {"GET", "/api/v3/stories/43"} ->
            Req.Test.json(conn, sc_story_payload())
        end
      end)

      assert {:ok, :created, %Issue{} = bead} = Claim.claim(ws, "43")
      assert bead.tracker_type == :shortcut
      assert bead.tracker_ref == "43"
      assert bead.title == "Wire up the thing"
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
    test "creates beads for assigned-open issues with no bead, and closes orphan beads",
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
      assert [{:create, "43", %{title: "Issue 43"}}, {:close, _bead_id, _reason}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert length(results) == 2
      assert Enum.any?(results, &match?({:created, _}, &1))
      assert Enum.any?(results, &match?({:closed, _}, &1))

      beads =
        Ash.read!(Issue)
        |> Enum.filter(&(&1.workspace_id == ws.id))

      bead_43 = Enum.find(beads, &(&1.tracker_ref == "43"))
      bead_44 = Enum.find(beads, &(&1.tracker_ref == "44"))

      assert bead_43.status == :open
      assert bead_44.status == :closed
    end

    test "empty plan when tracker doesn't support claim", %{none_ws: ws} do
      assert {:ok, []} = Claim.plan(ws)
    end
  end

  describe "plan/1 and apply_plan/2 — Jira" do
    test "creates beads for assigned open Jira issues with no bead", %{jira_ws: ws} do
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
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:create, "TEST-43", _}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert [{:created, bead}] = results
      assert bead.tracker_type == :jira
      assert bead.tracker_ref == "TEST-43"
    end
  end

  describe "plan/1 and apply_plan/2 — Shortcut" do
    test "creates beads for assigned open Shortcut stories with no bead", %{sc_ws: ws} do
      stub_sc(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => @sc_member_id})

          {"POST", "/api/v3/stories/search"} ->
            Req.Test.json(conn, [sc_story_payload()])

          {"GET", "/api/v3/stories/43"} ->
            Req.Test.json(conn, sc_story_payload())
        end
      end)

      assert {:ok, plan} = Claim.plan(ws)
      assert [{:create, "43", _}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert [{:created, bead}] = results
      assert bead.tracker_type == :shortcut
      assert bead.tracker_ref == "43"
    end
  end
end
