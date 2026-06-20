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

    test "blocked classifies as :needs_approval" do
      assert block_get(%{"mergeable_state" => "blocked"}).block_reason == :needs_approval
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
end
