defmodule Arbiter.Mergers.GithubTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Github.{Config, Error}

  @owner "octo"
  @repo "widget"
  @ref "#42"
  @env_var "GTE_GITHUB_MERGER_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")

    Config.put_active(%{
      "owner" => @owner,
      "repo" => @repo,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main",
      "default_reviewers" => ["alice"],
      "merge_method" => "squash"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  describe "open/4" do
    test "POSTs to /repos/:owner/:repo/pulls and returns {:ok, mr_ref}" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert Jason.decode!(body) == %{
                     "head" => "feature/x",
                     "base" => "main",
                     "title" => "Add thing",
                     "body" => "does the thing",
                     "draft" => false
                   }

            assert ["Bearer test-github-token"] = Plug.Conn.get_req_header(conn, "authorization")

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 42, "state" => "open"})

          {"POST", "/repos/octo/widget/pulls/42/requested_reviewers"} ->
            # default_reviewers (["alice"]) requested after open
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body) == %{"reviewers" => ["alice"]}

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{})
        end
      end)

      assert {:ok, "#42"} =
               Github.open("feature/x", "Add thing", "does the thing", %{})
    end

    test "honours target_branch / reviewer_ids / draft from opts" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["base"] == "develop"
            assert decoded["draft"] == true

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 7})

          {"POST", "/repos/octo/widget/pulls/7/requested_reviewers"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body) == %{"reviewers" => ["bob", "carol"]}

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{})
        end
      end)

      assert {:ok, "#7"} =
               Github.open("feature/y", "T", "B", %{
                 target_branch: "develop",
                 reviewer_ids: ["bob", "carol"],
                 draft: true
               })
    end

    test "does not request reviewers when none are configured or passed" do
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}"
      })

      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/repos/octo/widget/pulls"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 99})
      end)

      assert {:ok, "#99"} = Github.open("feature/z", "T", "B", %{})
    end

    test "422 (non-duplicate) maps to {:error, %Error{kind: :validation_failed}}" do
      stub(fn conn ->
        # The POST attempt fails; on a non-"already exists" 422 we should NOT
        # fall through to the duplicate-lookup path.
        assert {conn.method, conn.request_path} == {"POST", "/repos/octo/widget/pulls"}

        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422, message: "Validation Failed"}} =
               Github.open("x", "T", "B", %{})
    end

    test "422 'already exists' resolves the existing open PR and returns its ref" do
      branch = "feature/x"

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls"} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "Validation Failed",
              "errors" => [
                %{
                  "code" => "custom",
                  "message" => "A pull request already exists for octo:#{branch}."
                }
              ]
            })

          {"GET", "/repos/octo/widget/pulls"} ->
            # Pre-existing PR lookup: must be scoped to head=owner:branch and
            # state=open so we resolve the right one.
            assert conn.query_string =~ "head=octo%3A#{URI.encode_www_form(branch)}"
            assert conn.query_string =~ "state=open"

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"number" => 68, "state" => "open", "head" => %{"ref" => branch}}
            ])
        end
      end)

      assert {:ok, "#68"} = Github.open(branch, "Add thing", "does the thing", %{})
    end

    test "422 'already exists' but lookup returns no PRs falls back to 422 error" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls"} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "Validation Failed",
              "errors" => [
                %{"code" => "custom", "message" => "A pull request already exists for x."}
              ]
            })

          {"GET", "/repos/octo/widget/pulls"} ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Github.open("ghost-branch", "T", "B", %{})
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()
      assert {:error, %Error{kind: :config_missing}} = Github.open("x", "T", "B", %{})
    end
  end

  describe "get/1" do
    test "open PR with one approval is :open and approved" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 42,
              "state" => "open",
              "merged" => false,
              "html_url" => "https://github.com/octo/widget/pull/42"
            })

          "/repos/octo/widget/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"state" => "COMMENTED"},
              %{"state" => "APPROVED"}
            ])
        end
      end)

      assert {:ok,
              %{
                ref: "#42",
                status: :open,
                approved: true,
                url: "https://github.com/octo/widget/pull/42"
              }} = Github.get(@ref)
    end

    test "merged PR is :merged" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "closed", "merged" => true, "html_url" => "u"})

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok, %{status: :merged, approved: false}} = Github.get(@ref)
    end

    test "closed-but-not-merged PR is :closed" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "closed", "merged" => false, "html_url" => "u"})

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok, %{status: :closed}} = Github.get(@ref)
    end

    test "approved is false when a CHANGES_REQUESTED review exists" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "open", "merged" => false, "html_url" => "u"})

          "/repos/octo/widget/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"state" => "APPROVED"},
              %{"state" => "CHANGES_REQUESTED"}
            ])
        end
      end)

      assert {:ok, %{approved: false}} = Github.get(@ref)
    end

    test "404 on the PR returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} = Github.get(@ref)
    end

    test "includes pipeline status from check-runs when all pass" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "state" => "open",
              "merged" => false,
              "html_url" => "u",
              "head" => %{"sha" => "abc123"}
            })

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/repos/octo/widget/commits/abc123/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [
                %{"status" => "completed", "conclusion" => "success"},
                %{"status" => "completed", "conclusion" => "success"}
              ]
            })
        end
      end)

      assert {:ok, %{pipeline: :success}} = Github.get(@ref)
    end

    test "pipeline is :failed when any check-run has a failure conclusion" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "state" => "open",
              "merged" => false,
              "html_url" => "u",
              "head" => %{"sha" => "def456"}
            })

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/repos/octo/widget/commits/def456/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [
                %{"status" => "completed", "conclusion" => "success"},
                %{"status" => "completed", "conclusion" => "failure"}
              ]
            })
        end
      end)

      assert {:ok, %{pipeline: :failed}} = Github.get(@ref)
    end

    test "pipeline is :running when any check-run is in_progress" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "state" => "open",
              "merged" => false,
              "html_url" => "u",
              "head" => %{"sha" => "ghi789"}
            })

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/repos/octo/widget/commits/ghi789/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [
                %{"status" => "completed", "conclusion" => "success"},
                %{"status" => "in_progress", "conclusion" => nil}
              ]
            })
        end
      end)

      assert {:ok, %{pipeline: :running}} = Github.get(@ref)
    end

    test "pipeline is nil when no check-runs exist" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "state" => "open",
              "merged" => false,
              "html_url" => "u",
              "head" => %{"sha" => "jkl012"}
            })

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/repos/octo/widget/commits/jkl012/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"check_runs" => []})
        end
      end)

      assert {:ok, %{pipeline: nil}} = Github.get(@ref)
    end
  end

  # bd-95lsjb: the MergeQueue reads `changes_requested` + `latest_review_id` from
  # get/1 to drive the auto-revise path. Derived from the reviews get/1 already
  # fetches — no extra HTTP call.
  describe "get/1 changes_requested signal" do
    defp get_with_reviews(reviews) do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "open", "merged" => false, "html_url" => "u"})

          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(reviews)
        end
      end)

      Github.get(@ref)
    end

    test "changes_requested true + latest_review_id set when latest verdict is CHANGES_REQUESTED" do
      assert {:ok, %{changes_requested: true, latest_review_id: 100, approved: false}} =
               get_with_reviews([
                 %{"id" => 100, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}}
               ])
    end

    test "a later APPROVE from the same reviewer clears changes_requested (latest verdict wins)" do
      # The CHANGES_REQUESTED review still lives in history, but alice's latest
      # verdict is APPROVED — this is the post-revise re-approval the MergeQueue
      # relies on to advance to merge.
      assert {:ok, %{changes_requested: false, approved: true}} =
               get_with_reviews([
                 %{"id" => 100, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}},
                 %{"id" => 200, "state" => "APPROVED", "user" => %{"login" => "alice"}}
               ])
    end

    test "another reviewer's CHANGES_REQUESTED still blocks even with an APPROVE" do
      assert {:ok, %{changes_requested: true, approved: false, latest_review_id: 201}} =
               get_with_reviews([
                 %{"id" => 200, "state" => "APPROVED", "user" => %{"login" => "alice"}},
                 %{"id" => 201, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "bob"}}
               ])
    end

    test "no reviews → changes_requested false, latest_review_id nil" do
      assert {:ok, %{changes_requested: false, latest_review_id: nil}} = get_with_reviews([])
    end

    test "COMMENTED-only reviews don't set changes_requested" do
      assert {:ok, %{changes_requested: false, latest_review_id: nil}} =
               get_with_reviews([%{"state" => "COMMENTED", "user" => %{"login" => "alice"}}])
    end
  end

  # #354 Phase 1: get/1 classifies *why* an open PR can't merge so the Warden
  # (Watchdog) can escalate a blocked merge instead of parking it silently.
  describe "get/1 block_reason (#354)" do
    defp block_get(pr_fields, check_runs \\ []) do
      pr = Map.merge(%{"state" => "open", "merged" => false, "html_url" => "u"}, pr_fields)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/octo/widget/pulls/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr)

          conn.request_path == "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          String.contains?(conn.request_path, "/check-runs") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"check_runs" => check_runs})
        end
      end)

      {:ok, result} = Github.get(@ref)
      result
    end

    test "clean / mergeable PR has no block reason" do
      assert block_get(%{"mergeable_state" => "clean", "mergeable" => true}).block_reason == nil
    end

    test "dirty merge state classifies as :conflict" do
      assert block_get(%{"mergeable_state" => "dirty"}).block_reason == :conflict
    end

    test "mergeable=false classifies as :conflict even without a merge-state string" do
      assert block_get(%{"mergeable" => false}).block_reason == :conflict
    end

    test "behind classifies as :behind_base" do
      assert block_get(%{"mergeable_state" => "behind"}).block_reason == :behind_base
    end

    test "blocked with no resolvable author classifies as :needs_approval" do
      # No `user.login` on the PR → authorship can't be confirmed as the fleet's,
      # so we never even call `/user` and fall back to the generic reason.
      assert block_get(%{"mergeable_state" => "blocked"}).block_reason == :needs_approval
    end

    # A blocked PR whose author IS the authenticated fleet identity is parked on a
    # required non-author approval the fleet can never supply (bd-c3lchp).
    defp block_get_authored(pr_fields, viewer_login) do
      pr = Map.merge(%{"state" => "open", "merged" => false, "html_url" => "u"}, pr_fields)

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/octo/widget/pulls/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr)

          conn.request_path == "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.request_path == "/user" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"login" => viewer_login})

          String.contains?(conn.request_path, "/check-runs") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"check_runs" => []})
        end
      end)

      {:ok, result} = Github.get(@ref)
      result
    end

    test "blocked on a fleet-authored PR classifies as :needs_nonauthor_approval" do
      result =
        block_get_authored(
          %{"mergeable_state" => "blocked", "user" => %{"login" => "fleet-bot"}},
          "fleet-bot"
        )

      assert result.block_reason == :needs_nonauthor_approval
    end

    test "blocked on a PR authored by someone else stays :needs_approval" do
      result =
        block_get_authored(
          %{"mergeable_state" => "blocked", "user" => %{"login" => "a-human"}},
          "fleet-bot"
        )

      assert result.block_reason == :needs_approval
    end

    test "blocked with CHANGES_REQUESTED stays :needs_approval even when fleet-authored" do
      # An outstanding change request is a real review action, not the
      # author-can't-self-approve park case — keep the revise-able reason.
      pr = %{
        "state" => "open",
        "merged" => false,
        "html_url" => "u",
        "mergeable_state" => "blocked",
        "user" => %{"login" => "fleet-bot"}
      }

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/octo/widget/pulls/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pr)

          conn.request_path == "/repos/octo/widget/pulls/42/reviews" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED", "user" => %{"login" => "rev"}}])

          conn.request_path == "/user" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"login" => "fleet-bot"})

          String.contains?(conn.request_path, "/check-runs") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"check_runs" => []})
        end
      end)

      assert {:ok, result} = Github.get(@ref)
      assert result.block_reason == :needs_approval
    end

    test "draft classifies as :draft" do
      assert block_get(%{"draft" => true, "mergeable_state" => "draft"}).block_reason == :draft
    end

    test "a failing check-run classifies as :ci_failed" do
      result =
        block_get(
          %{"mergeable_state" => "unstable", "head" => %{"sha" => "abc123"}},
          [%{"status" => "completed", "conclusion" => "failure"}]
        )

      assert result.block_reason == :ci_failed
    end

    test "a merged PR carries no block reason" do
      assert block_get(%{"state" => "closed", "merged" => true}).block_reason == nil
    end
  end

  describe "list_review_feedback/1" do
    test "returns the latest verdict body + inline comments" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/octo/widget/pulls/42/reviews"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{
                "id" => 100,
                "state" => "CHANGES_REQUESTED",
                "user" => %{"login" => "alice"},
                "body" => "Please add tests and fix the naming."
              },
              # a bodiless review is dropped from the feedback list
              %{"id" => 101, "state" => "COMMENTED", "user" => %{"login" => "bob"}, "body" => ""}
            ])

          {"GET", "/repos/octo/widget/pulls/42/comments"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{
                "user" => %{"login" => "alice"},
                "path" => "lib/foo.ex",
                "line" => 12,
                "body" => "rename this function"
              }
            ])
        end
      end)

      assert {:ok, %{changes_requested: true, latest_review_id: 100, feedback: feedback}} =
               Github.list_review_feedback(@ref)

      assert [
               %{kind: :review, author: "alice", state: "CHANGES_REQUESTED", body: review_body},
               %{
                 kind: :comment,
                 author: "alice",
                 path: "lib/foo.ex",
                 line: 12,
                 body: comment_body
               }
             ] = feedback

      assert review_body =~ "add tests"
      assert comment_body =~ "rename"
    end

    test "no reviews and no comments → empty feedback, changes_requested false" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/repos/octo/widget/pulls/42/comments" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}} =
               Github.list_review_feedback(@ref)
    end

    test "404 on reviews surfaces {:error, %Error{}}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found}} = Github.list_review_feedback(@ref)
    end
  end

  describe "list_open/0" do
    test "GETs open PRs and returns embedded mr_refs" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"GET", "/repos/octo/widget/pulls"}
        assert conn.query_string =~ "state=open"
        assert conn.query_string =~ "per_page=100"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json([
          %{
            "number" => 42,
            "title" => "Add lea_reports passthrough",
            "html_url" => "https://gh/pr/42"
          }
        ])
      end)

      assert {:ok, [mr]} = Github.list_open()
      assert mr.ref == "octo/widget#42"
      assert mr.number == 42
      assert mr.title == "Add lea_reports passthrough"
      assert mr.url == "https://gh/pr/42"
    end

    test "missing owner/repo in cfg → {:error, %Error{kind: :config_missing}}" do
      # Only credentials are configured — neither owner nor repo is set, and
      # list_open/0 takes no :repo_path to derive them from, so it must surface
      # a config_missing error rather than hitting the API with a bad path.
      Config.put_active(%{"credentials_ref" => "env:#{@env_var}"})

      assert {:error, %Error{kind: :config_missing}} = Github.list_open()
    end
  end

  describe "list_open_review_threads/1" do
    test "POSTs the GraphQL query and returns only unresolved threads, normalized" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] =~ "reviewThreads"
        assert decoded["query"] =~ "databaseId"
        assert decoded["variables"] == %{"owner" => "octo", "repo" => "widget", "number" => 42}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "reviewThreads" => %{
                  "nodes" => [
                    %{
                      "id" => "RT_open",
                      "isResolved" => false,
                      "path" => "lib/foo.ex",
                      "line" => 12,
                      "comments" => %{
                        "nodes" => [
                          %{
                            "databaseId" => 101,
                            "body" => "consider renaming",
                            "author" => %{"login" => "copilot"}
                          }
                        ]
                      }
                    },
                    %{
                      "id" => "RT_resolved",
                      "isResolved" => true,
                      "path" => "lib/bar.ex",
                      "line" => 3,
                      "comments" => %{
                        "nodes" => [
                          %{"databaseId" => 99, "body" => "done", "author" => %{"login" => "x"}}
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        })
      end)

      assert {:ok, [thread]} = Github.list_open_review_threads(@ref)
      assert thread.id == "RT_open"
      assert thread.resolved == false
      assert thread.path == "lib/foo.ex"
      assert thread.line == 12
      assert thread.author == "copilot"
      assert thread.body == "consider renaming"
      assert [%{id: 101, author: "copilot", body: "consider renaming"}] = thread.comments
    end

    test "returns full comment list with ids and authors for each thread" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "reviewThreads" => %{
                  "nodes" => [
                    %{
                      "id" => "RT_multi",
                      "isResolved" => false,
                      "path" => "lib/server.ex",
                      "line" => 5,
                      "comments" => %{
                        "nodes" => [
                          %{
                            "databaseId" => 200,
                            "body" => "opening comment",
                            "author" => %{"login" => "bot"}
                          },
                          %{
                            "databaseId" => 201,
                            "body" => "reply from human",
                            "author" => %{"login" => "alice"}
                          },
                          %{
                            "databaseId" => 202,
                            "body" => "bot follow-up",
                            "author" => %{"login" => "bot"}
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        })
      end)

      assert {:ok, [thread]} = Github.list_open_review_threads(@ref)
      assert thread.author == "bot"
      assert thread.body == "opening comment"
      assert length(thread.comments) == 3
      assert Enum.map(thread.comments, & &1.id) == [200, 201, 202]
      assert Enum.map(thread.comments, & &1.author) == ["bot", "alice", "bot"]
    end

    test "no review threads → {:ok, []}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => []}}}
          }
        })
      end)

      assert {:ok, []} = Github.list_open_review_threads(@ref)
    end

    test "GraphQL query-level errors (HTTP 200 with errors) surface as {:error, %Error{}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"errors" => [%{"message" => "Could not resolve to a Repository"}]})
      end)

      assert {:error, %Error{message: "Could not resolve to a Repository"}} =
               Github.list_open_review_threads(@ref)
    end
  end

  describe "reply_to_review_comment/4" do
    test "POSTs a reply to the given comment id and returns {:ok, comment_payload}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/pulls/42/comments/101/replies"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "Thanks, fixed!"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 202, "body" => "Thanks, fixed!"})
      end)

      assert {:ok, %{"id" => 202}} =
               Github.reply_to_review_comment(@ref, 101, "Thanks, fixed!", %{})
    end

    test "works with an embedded owner/repo ref" do
      stub(fn conn ->
        assert conn.request_path ==
                 "/repos/leo-technologies-llc/verus_server/pulls/7/comments/55/replies"

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 56})
      end)

      assert {:ok, _} =
               Github.reply_to_review_comment(
                 "leo-technologies-llc/verus_server#7",
                 55,
                 "LGTM",
                 %{}
               )
    end

    test "404 on the comment returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} =
               Github.reply_to_review_comment(@ref, 999, "oops", %{})
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} =
               Github.reply_to_review_comment(@ref, 1, "hi", %{})
    end
  end

  describe "resolve_review_thread/3" do
    test "POSTs the resolveReviewThread mutation and returns {:ok, thread}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] =~ "resolveReviewThread"
        assert decoded["variables"] == %{"id" => "RT_open"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "resolveReviewThread" => %{"thread" => %{"id" => "RT_open", "isResolved" => true}}
          }
        })
      end)

      assert {:ok, %{"id" => "RT_open", "isResolved" => true}} =
               Github.resolve_review_thread(@ref, "RT_open", %{})
    end

    test "GraphQL query-level errors (HTTP 200 with errors) surface as {:error, %Error{}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"errors" => [%{"message" => "Could not resolve to a node"}]})
      end)

      assert {:error, %Error{message: "Could not resolve to a node"}} =
               Github.resolve_review_thread(@ref, "RT_bad", %{})
    end

    test "HTTP error status surfaces as {:error, %Error{}}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:error, %Error{status: 401}} = Github.resolve_review_thread(@ref, "RT_x", %{})
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} =
               Github.resolve_review_thread(@ref, "RT_x", %{})
    end
  end

  describe "filter_to_our_threads/2" do
    defp make_thread(id, author, comment_authors) do
      comments =
        Enum.map(comment_authors, fn a -> %{id: :rand.uniform(9999), author: a, body: ""} end)

      %{id: id, author: author, body: "x", resolved: false, comments: comments}
    end

    test "keeps threads where our_login authored the opening comment" do
      threads = [
        make_thread("T1", "bot", ["bot", "alice"]),
        make_thread("T2", "alice", ["alice"]),
        make_thread("T3", "carol", ["carol"])
      ]

      result = Github.filter_to_our_threads(threads, "bot")
      assert Enum.map(result, & &1.id) == ["T1"]
    end

    test "keeps threads where our_login replied even if someone else opened" do
      threads = [
        make_thread("T1", "alice", ["alice", "bot"]),
        make_thread("T2", "carol", ["carol", "dave"])
      ]

      result = Github.filter_to_our_threads(threads, "bot")
      assert Enum.map(result, & &1.id) == ["T1"]
    end

    test "returns empty list when no threads belong to our_login" do
      threads = [
        make_thread("T1", "alice", ["alice"]),
        make_thread("T2", "carol", ["carol", "dave"])
      ]

      assert [] = Github.filter_to_our_threads(threads, "bot")
    end

    test "returns all matching threads when our_login appears in multiple" do
      threads = [
        make_thread("T1", "bot", ["bot"]),
        make_thread("T2", "alice", ["alice", "bot"]),
        make_thread("T3", "carol", ["carol"])
      ]

      result = Github.filter_to_our_threads(threads, "bot")
      assert Enum.map(result, & &1.id) == ["T1", "T2"]
    end

    test "handles threads with no comments key (author-only match)" do
      threads = [
        %{id: "T1", author: "bot", body: "x"},
        %{id: "T2", author: "alice", body: "y"}
      ]

      result = Github.filter_to_our_threads(threads, "bot")
      assert Enum.map(result, & &1.id) == ["T1"]
    end
  end

  describe "merge/1" do
    test "PUTs /merge with the configured merge_method" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/repos/octo/widget/pulls/42/merge"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"merge_method" => "squash"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"merged" => true})
      end)

      assert :ok = Github.merge(@ref)
    end

    test "405 (not mergeable) maps to {:error, %Error{kind: :not_mergeable}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(405)
        |> Req.Test.json(%{"message" => "Pull Request is not mergeable"})
      end)

      assert {:error, %Error{kind: :not_mergeable, status: 405}} = Github.merge(@ref)
    end

    test "409 (conflict) maps to {:error, %Error{kind: :conflict}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"message" => "Head branch was modified"})
      end)

      assert {:error, %Error{kind: :conflict, status: 409}} = Github.merge(@ref)
    end

    test "uses merge_method from config when overridden" do
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}",
        "merge_method" => "rebase"
      })

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"merge_method" => "rebase"}

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
      end)

      assert :ok = Github.merge(@ref)
    end
  end

  describe "update_branch/1 (#354, Phase 3)" do
    test "PUTs /pulls/:n/update-branch and returns :ok on 202 Accepted" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/repos/octo/widget/pulls/42/update-branch"

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"message" => "Updating pull request branch."})
      end)

      assert :ok = Github.update_branch(@ref)
    end

    test "422 (can't update cleanly) maps to {:error, %Error{}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "merge conflict between base and head"})
      end)

      assert {:error, %Error{status: 422}} = Github.update_branch(@ref)
    end

    test "resolves an embedded owner/repo ref for the update-branch path" do
      stub(fn conn ->
        assert conn.request_path ==
                 "/repos/leo-technologies-llc/verus_server/pulls/7/update-branch"

        conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{})
      end)

      assert :ok = Github.update_branch("leo-technologies-llc/verus_server#7")
    end
  end

  describe "failing_check_logs/1 (#354 Phase 2a)" do
    test "returns the failing checks (name + output tail + url), skipping passing ones" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "open", "head" => %{"sha" => "sha1"}})

          "/repos/octo/widget/commits/sha1/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [
                %{"name" => "lint", "conclusion" => "success"},
                %{
                  "name" => "test",
                  "conclusion" => "failure",
                  "details_url" => "https://github.com/octo/widget/runs/9",
                  "output" => %{
                    "title" => "5 tests failed",
                    "summary" => "lib/foo_test.exs:12 assertion failed"
                  }
                }
              ]
            })
        end
      end)

      assert {:ok, [check]} = Github.failing_check_logs(@ref)
      assert check.name == "test"
      assert check.url == "https://github.com/octo/widget/runs/9"
      assert check.summary =~ "5 tests failed"
      assert check.summary =~ "assertion failed"
    end

    test "returns an empty list when there is no head sha" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"state" => "open"})
        end
      end)

      assert {:ok, []} = Github.failing_check_logs(@ref)
    end

    test "returns an empty list when no checks are failing" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "open", "head" => %{"sha" => "sha2"}})

          "/repos/octo/widget/commits/sha2/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [%{"name" => "test", "conclusion" => "success"}]
            })
        end
      end)

      assert {:ok, []} = Github.failing_check_logs(@ref)
    end

    test "treats timed_out / cancelled / action_required as failing" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"state" => "open", "head" => %{"sha" => "sha3"}})

          "/repos/octo/widget/commits/sha3/check-runs" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "check_runs" => [
                %{"name" => "a", "conclusion" => "timed_out"},
                %{"name" => "b", "conclusion" => "cancelled"},
                %{"name" => "c", "conclusion" => "action_required"}
              ]
            })
        end
      end)

      assert {:ok, checks} = Github.failing_check_logs(@ref)
      assert Enum.map(checks, & &1.name) == ["a", "b", "c"]
    end
  end

  describe "list_required_check_failures/1 (bd-ayetel)" do
    defp stub_required_checks(nodes) do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "commits" => %{
                  "nodes" => [
                    %{
                      "commit" => %{
                        "statusCheckRollup" => %{
                          "contexts" => %{"nodes" => nodes}
                        }
                      }
                    }
                  ]
                }
              }
            }
          }
        })
      end)
    end

    test "returns only settled-failing REQUIRED CheckRun contexts" do
      stub_required_checks([
        %{
          "__typename" => "CheckRun",
          "name" => "ui-integration-tests",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "detailsUrl" => "https://github.com/octo/widget/runs/9",
          "isRequired" => true
        },
        # optional check, also failing — must be excluded
        %{
          "__typename" => "CheckRun",
          "name" => "lint-optional",
          "status" => "COMPLETED",
          "conclusion" => "FAILURE",
          "isRequired" => false
        },
        # required but still running — must be excluded (transient, not settled)
        %{
          "__typename" => "CheckRun",
          "name" => "build",
          "status" => "IN_PROGRESS",
          "conclusion" => nil,
          "isRequired" => true
        },
        # required and settled green — must be excluded
        %{
          "__typename" => "CheckRun",
          "name" => "unit-tests",
          "status" => "COMPLETED",
          "conclusion" => "SUCCESS",
          "isRequired" => true
        }
      ])

      assert {:ok, [check]} = Github.list_required_check_failures(@ref)
      assert check.name == "ui-integration-tests"
      assert check.url == "https://github.com/octo/widget/runs/9"
    end

    test "returns only settled-failing REQUIRED legacy StatusContext entries" do
      stub_required_checks([
        %{
          "__typename" => "StatusContext",
          "context" => "ci/required-status",
          "state" => "FAILURE",
          "targetUrl" => "https://ci.example.com/1",
          "description" => "build failed",
          "isRequired" => true
        },
        %{
          "__typename" => "StatusContext",
          "context" => "ci/optional-status",
          "state" => "FAILURE",
          "isRequired" => false
        },
        %{
          "__typename" => "StatusContext",
          "context" => "ci/pending-status",
          "state" => "PENDING",
          "isRequired" => true
        }
      ])

      assert {:ok, [check]} = Github.list_required_check_failures(@ref)
      assert check.name == "ci/required-status"
      assert check.summary =~ "build failed"
    end

    test "returns an empty list when nothing is failing" do
      stub_required_checks([
        %{
          "__typename" => "CheckRun",
          "name" => "unit-tests",
          "status" => "COMPLETED",
          "conclusion" => "SUCCESS",
          "isRequired" => true
        }
      ])

      assert {:ok, []} = Github.list_required_check_failures(@ref)
    end
  end

  describe "close/1" do
    test "PATCHes the PR to state: closed" do
      stub(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/repos/octo/widget/pulls/42"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"state" => "closed"}

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"state" => "closed"})
      end)

      assert :ok = Github.close(@ref)
    end
  end

  describe "add_comment/2" do
    test "POSTs a comment to the issues endpoint" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/issues/42/comments"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "looks good"}

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end)

      assert :ok = Github.add_comment(@ref, "looks good")
    end
  end

  describe "request_review/2" do
    test "POSTs the reviewers to the requested_reviewers endpoint" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/pulls/42/requested_reviewers"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"reviewers" => ["dave"]}

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
      end)

      assert :ok = Github.request_review(@ref, ["dave"])
    end

    test "is a no-op for an empty reviewer list" do
      # No stub installed: an unexpected request would fail the test.
      assert :ok = Github.request_review(@ref, [])
    end
  end

  describe "link_for/1" do
    test "builds the PR URL from the active workspace owner/repo" do
      assert Github.link_for(@ref) == "https://github.com/octo/widget/pull/42"
    end

    test "falls back to a placeholder slug when no workspace is set" do
      Config.clear()
      assert Github.link_for(@ref) =~ "/pull/42"
    end
  end

  describe "Mergers integration" do
    test "Mergers.for_strategy(:github) resolves to this adapter (no raise)" do
      assert Arbiter.Mergers.for_strategy(:github) == Github
    end
  end

  describe "per-repo repo derivation (workspace cfg without :repo)" do
    setup do
      # Build a tmp git repo whose origin remote is set so the adapter can
      # derive owner/repo from it. The repo never has any commits — only the
      # remote URL is exercised by `git remote get-url origin`.
      tmp = System.tmp_dir!()
      repo_dir = Path.join(tmp, "arbiter_github_perrepo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo_dir)
      {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch=main", repo_dir])

      {_, 0} =
        System.cmd("git", [
          "-C",
          repo_dir,
          "remote",
          "add",
          "origin",
          "git@github.com:leo-technologies-llc/verus_server.git"
        ])

      # Workspace cfg has owner + token but no repo — the multi-repo shape.
      Config.put_active(%{
        "owner" => "leo-technologies-llc",
        "credentials_ref" => "env:#{@env_var}",
        "default_target_branch" => "main"
      })

      on_exit(fn -> File.rm_rf!(repo_dir) end)

      {:ok, repo_dir: repo_dir}
    end

    test "open/4 derives owner/repo from :repo_path and embeds them in mr_ref", %{
      repo_dir: repo_dir
    } do
      stub(fn conn ->
        assert {conn.method, conn.request_path} ==
                 {"POST", "/repos/leo-technologies-llc/verus_server/pulls"}

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 7})
      end)

      assert {:ok, "leo-technologies-llc/verus_server#7"} =
               Github.open("feature/x", "T", "B", %{repo_path: repo_dir})
    end

    test "get/1 routes to the embedded owner/repo, not the cfg one" do
      # We supply a workspace cfg with no `repo` AND a different owner to
      # prove the adapter trusts the mr_ref, not the cfg, on read.
      stub(fn conn ->
        case conn.request_path do
          "/repos/leo-technologies-llc/verus_server/pulls/7" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "state" => "open",
              "merged" => false,
              "html_url" => "https://github.com/leo-technologies-llc/verus_server/pull/7"
            })

          "/repos/leo-technologies-llc/verus_server/pulls/7/reviews" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok,
              %{
                ref: "leo-technologies-llc/verus_server#7",
                status: :open,
                url: "https://github.com/leo-technologies-llc/verus_server/pull/7"
              }} = Github.get("leo-technologies-llc/verus_server#7")
    end

    test "merge/1 routes to the embedded owner/repo" do
      stub(fn conn ->
        assert conn.method == "PUT"

        assert conn.request_path ==
                 "/repos/leo-technologies-llc/verus_server/pulls/7/merge"

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})
      end)

      assert :ok = Github.merge("leo-technologies-llc/verus_server#7")
    end

    test "open/4 with NO owner in cfg still derives both owner and repo from :repo_path (bd-a53kv2)",
         %{repo_dir: repo_dir} do
      # Workspace cfg carries only credentials — both owner and repo are absent.
      # This is the "single-repo workspace after merge.config.repo + owner removal"
      # shape: everything is derived per-repo from the git remote.
      Config.put_active(%{"credentials_ref" => "env:#{@env_var}"})

      stub(fn conn ->
        assert {conn.method, conn.request_path} ==
                 {"POST", "/repos/leo-technologies-llc/verus_server/pulls"}

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 5})
      end)

      assert {:ok, "leo-technologies-llc/verus_server#5"} =
               Github.open("feature/x", "T", "B", %{repo_path: repo_dir})
    end

    test "open/4 errors when cfg has no repo AND opts has no :repo_path" do
      assert {:error, %Error{kind: :config_missing}} =
               Github.open("feature/x", "T", "B", %{})
    end

    test "open/4 errors when :repo_path points at a non-git path" do
      tmp = System.tmp_dir!()
      bad = Path.join(tmp, "arbiter_perrig_not_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bad)
      on_exit(fn -> File.rm_rf!(bad) end)

      assert {:error, %Error{kind: :config_missing}} =
               Github.open("feature/x", "T", "B", %{repo_path: bad})
    end

    test "link_for/1 with embedded mr_ref uses the embedded owner/repo" do
      assert Github.link_for("leo-technologies-llc/verus_server#7") ==
               "https://github.com/leo-technologies-llc/verus_server/pull/7"
    end

    test "workspace cfg repo wins over per-repo derivation when both are present", %{
      repo_dir: repo_dir
    } do
      # Re-pin the workspace cfg to include `repo` — the repo dir's remote points
      # at verus_server, but the cfg should still win (single-repo workspace
      # backwards-compat).
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}"
      })

      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/repos/octo/widget/pulls"}
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 9})
      end)

      assert {:ok, "#9"} = Github.open("feature/x", "T", "B", %{repo_path: repo_dir})
    end
  end

  describe "submit_review/4" do
    test "submits an APPROVE review via the reviews endpoint" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} ==
                 {"POST", "/repos/octo/widget/pulls/42/reviews"}

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["event"] == "APPROVE"
        assert decoded["body"] == "Approved: no findings."

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 1})
      end)

      assert {:ok, _} = Github.submit_review(@ref, :approve, "Approved: no findings.", %{})
    end

    test "submits a REQUEST_CHANGES review via the reviews endpoint" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} ==
                 {"POST", "/repos/octo/widget/pulls/42/reviews"}

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["event"] == "REQUEST_CHANGES"

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 2})
      end)

      assert {:ok, _} = Github.submit_review(@ref, :request_changes, "Fix these.", %{})
    end

    test "422 'your own pull request' on APPROVE falls back to issue comment" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls/42/reviews"} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"message" => "Can not approve your own pull request."})

          {"POST", "/repos/octo/widget/issues/42/comments"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            comment = Jason.decode!(body)["body"]
            assert comment =~ "VERDICT: APPROVE"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 99})
        end
      end)

      assert {:ok, _} = Github.submit_review(@ref, :approve, "Approved.", %{})
    end

    test "422 'your own pull request' on REQUEST_CHANGES falls back to issue comment" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/repos/octo/widget/pulls/42/reviews"} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "You can not request changes on your own pull request."
            })

          {"POST", "/repos/octo/widget/issues/42/comments"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            comment = Jason.decode!(body)["body"]
            assert comment =~ "VERDICT: REQUEST_CHANGES"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 100})
        end
      end)

      assert {:ok, _} = Github.submit_review(@ref, :request_changes, "Fix these.", %{})
    end

    test "422 with an unrelated message is not treated as self-review" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Github.submit_review(@ref, :approve, "Approved.", %{})
    end
  end

  describe "with_workspace/2" do
    test "scopes config to the block and restores afterwards" do
      Config.clear()

      result =
        Github.with_workspace(
          %{
            "owner" => "other",
            "repo" => "thing",
            "credentials_ref" => "env:#{@env_var}"
          },
          fn -> Github.link_for("#5") end
        )

      assert result == "https://github.com/other/thing/pull/5"
      # After the block, config is cleared.
      assert {:error, %Error{kind: :config_missing}} = Github.get("#1")
    end
  end

  # ref_for_pr/2 — construct an mr_ref for an external PR (bd-d4ealy).
  describe "ref_for_pr/2" do
    test "parses a github.com PR URL into an embedded ref" do
      assert {:ok, "leo/verus_sigv4#5"} =
               Github.ref_for_pr("https://github.com/leo/verus_sigv4/pull/5", %{})
    end

    test "parses an enterprise-host PR URL (host is not constrained)" do
      assert {:ok, "org/proj#12"} =
               Github.ref_for_pr("https://github.example.com/org/proj/pull/12", %{})
    end

    test "parses an owner/repo#N slug" do
      assert {:ok, "octo/widget#42"} = Github.ref_for_pr("octo/widget#42", %{})
    end

    test "parses an owner/repo/pull/N slug" do
      assert {:ok, "octo/widget#7"} = Github.ref_for_pr("octo/widget/pull/7", %{})
    end

    test "a bare number with no repo_path mints a bare ref (falls back to active cfg)" do
      assert {:ok, "#42"} = Github.ref_for_pr("42", %{})
      assert {:ok, "#42"} = Github.ref_for_pr("#42", %{})
    end

    test "a bare number with a repo_path embeds the owner/repo from the origin remote" do
      repo = tmp_git_repo("git@github.com:leo/verus_auth_server.git")
      assert {:ok, "leo/verus_auth_server#394"} = Github.ref_for_pr("394", %{repo_path: repo})
    end

    test "a bare number with an unresolvable repo_path falls back to a bare ref" do
      dir = Path.join(System.tmp_dir!(), "no-remote-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert {:ok, "#9"} = Github.ref_for_pr("9", %{repo_path: dir})
    end

    test "an unparseable identifier returns a validation error" do
      assert {:error, %Error{kind: :validation_failed}} = Github.ref_for_pr("not a pr", %{})
    end
  end

  # Minimal git repo whose `origin` remote is set to the given URL, so
  # RepoResolver.from_remote/1 can derive {owner, repo}.
  defp tmp_git_repo(origin_url) do
    dir = Path.join(System.tmp_dir!(), "gh-ref-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", origin_url])
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
