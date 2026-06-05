defmodule Arbiter.Beads.ClaimTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Claim, Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config

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

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    {:ok, github_ws: github_ws, none_ws: none_ws}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

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

  describe "claim/3" do
    test "creates a bead mirrored from the issue when assigned to viewer", %{github_ws: ws} do
      stub(fn conn ->
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
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} -> Req.Test.json(conn, %{"login" => @viewer})
          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} -> Req.Test.json(conn, [])
          {"GET", _} -> Req.Test.json(conn, issue_payload())
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
      stub(fn conn ->
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
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} -> Req.Test.json(conn, %{"login" => @viewer})
          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} -> Req.Test.json(conn, [])
          {"GET", _} -> Req.Test.json(conn, issue_payload(%{"assignees" => []}))
          {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
          {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, _bead} = Claim.claim(ws, "43", force: true)
    end

    test "accepts decorated refs like '#43' and 'gh-43' and a full URL", %{github_ws: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} -> Req.Test.json(conn, %{"login" => @viewer})
          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} -> Req.Test.json(conn, [])
          {"GET", _} -> Req.Test.json(conn, issue_payload())
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
      assert {:error, {:invalid_ref, "not-a-number"}} = Claim.claim(ws, "not-a-number")
    end

    test "no-ops cleanly when the workspace tracker isn't github", %{none_ws: ws} do
      assert {:error, :tracker_not_github} = Claim.claim(ws, "43")
    end

    test "refuses when another Arbiter installation has already claimed the issue",
         %{github_ws: ws} do
      prior_body =
        "Claimed as other-bd-abc123 by other-fleet (other). Arbiter installation: other-host."

      stub(fn conn ->
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

      stub(fn conn ->
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

      stub(fn conn ->
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

      stub(fn conn ->
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

      # Second claim — must not post another comment.
      assert {:ok, :existing, _} = Claim.claim(ws, "43")
      refute_receive :comment_posted
    end

    test "comment-fetch failure does not abort a claim", %{github_ws: ws} do
      stub(fn conn ->
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

  describe "plan/1 and apply_plan/2" do
    test "creates beads for assigned-open issues with no bead, and closes orphan beads",
         %{github_ws: ws} do
      # Pre-seed: a bead for #44 already exists; the GitHub side will report
      # #44 as no-longer-assigned, so plan should close it. #43 is freshly
      # assigned with no bead → plan should create it.
      {:ok, _existing} =
        Ash.create(Issue, %{
          title: "Stale claim for 44",
          tracker_type: :github,
          tracker_ref: "44",
          workspace_id: ws.id
        })

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            # Listed issues = assigned + open. #43 is assigned; #44 is not in
            # the list (reassigned away).
            Req.Test.json(conn, [
              issue_payload(%{"number" => 43, "title" => "Issue 43"})
            ])

          {"GET", "/repos/ryanrborn/arbiter/issues/44"} ->
            # The reason-fetch for the orphan: returns the current state of
            # the issue (open, assigned to someone else).
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

      # Two actions, deterministically ordered: creates before closes.
      assert [{:create, "43", %{title: "Issue 43"}}, {:close, _bead_id, _reason}] = plan

      assert {:ok, results} = Claim.apply_plan(ws, plan)
      assert length(results) == 2
      assert Enum.any?(results, &match?({:created, _}, &1))
      assert Enum.any?(results, &match?({:closed, _}, &1))

      # Verify side-effects in the DB.
      beads =
        Ash.read!(Issue)
        |> Enum.filter(&(&1.workspace_id == ws.id))

      bead_43 = Enum.find(beads, &(&1.tracker_ref == "43"))
      bead_44 = Enum.find(beads, &(&1.tracker_ref == "44"))

      assert bead_43.status == :open
      assert bead_44.status == :closed
    end

    test "empty plan when tracker isn't github", %{none_ws: ws} do
      assert {:ok, []} = Claim.plan(ws)
    end
  end
end
