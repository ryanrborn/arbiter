defmodule Arbiter.Mergers.GitlabTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.{Config, Error}

  @host "gitlab.com"
  @project 12_345
  @iid 42
  @ref "!42"
  @env_var "GTE_GITLAB_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => @host,
      "project_id" => @project,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main",
      "default_reviewers" => [7]
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fun)

  defp base_path, do: "/api/v4/projects/#{@project}/merge_requests"

  describe "open/4" do
    test "201: POSTs the MR and returns {:ok, mr_ref}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == base_path()
        assert ["test-gitlab-token"] = Plug.Conn.get_req_header(conn, "private-token")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["source_branch"] == "feature/bd-9bn4n9"
        assert decoded["target_branch"] == "main"
        assert decoded["title"] == "Implement GitLab merger"
        assert decoded["reviewer_ids"] == [7]
        assert decoded["labels"] == "polecat,merger"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "iid" => @iid,
          "web_url" => "https://gitlab.com/x/-/merge_requests/42"
        })
      end)

      assert {:ok, @ref} =
               Gitlab.open("feature/bd-9bn4n9", "Implement GitLab merger", "body", %{
                 labels: ["polecat", "merger"]
               })
    end

    test "honours an explicit :target_branch and :reviewer_ids over the config defaults" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["target_branch"] == "develop"
        assert decoded["reviewer_ids"] == [1, 2]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      assert {:ok, @ref} =
               Gitlab.open("feature/x", "t", "d", %{
                 target_branch: "develop",
                 reviewer_ids: [1, 2]
               })
    end

    test "422: returns {:error, %Error{kind: :validation_failed}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => ["Source branch does not exist"]})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Gitlab.open("nope", "t", "d", %{})
    end

    test "422 'already exists': adopts the existing open MR" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => [
                "Another open merge request already exists for this source branch: feature/bd-4i8z1r"
              ]
            })

          "GET" ->
            assert conn.request_path == base_path()
            assert conn.query_string =~ "state=opened"
            assert conn.query_string =~ "source_branch="

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"iid" => @iid, "state" => "opened"}])
        end
      end)

      assert {:ok, @ref} = Gitlab.open("feature/bd-4i8z1r", "Fix something", "body", %{})
    end

    test "422 'already exists' but listing returns empty: returns conflict error" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => ["Another open merge request already exists for this source branch"]
            })

          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([])
        end
      end)

      assert {:error, %Error{kind: :conflict}} = Gitlab.open("feature/x", "t", "d", %{})
    end

    test "422 'already exists' with message as string instead of list: adopts existing MR" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "Another open merge request already exists for this source branch"
            })

          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"iid" => @iid, "state" => "opened"}])
        end
      end)

      assert {:ok, @ref} = Gitlab.open("feature/x", "t", "d", %{})
    end

    test "when repo_path is provided but branch doesn't exist: returns git_push_failed error" do
      # Use a branch name that likely doesn't exist on the remote
      bad_branch = "feature/nonexistent-branch-#{System.unique_integer()}"
      repo_dir = File.cwd!()

      # Don't stub the HTTP call — we should fail at the git push step before reaching it
      result = Gitlab.open(bad_branch, "Test", "desc", %{repo_path: repo_dir})

      # The push should fail because the branch doesn't exist
      assert {:error, %Error{kind: :git_push_failed, message: msg}} = result
      assert String.contains?(msg, "Failed to push branch")
    end

    test "when repo_path points to non-existent dir: returns git_push_failed error" do
      stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"iid" => @iid}) end)

      non_existent = "/tmp/does_not_exist_#{System.unique_integer()}/repo"

      assert {:error, %Error{kind: :git_push_failed, message: msg}} =
               Gitlab.open("feature/x", "t", "d", %{repo_path: non_existent})

      assert String.contains?(msg, "Failed to push branch")
    end

    test "when repo_path is not provided: skips push and creates MR normally" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == base_path()

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      # Call open without repo_path — should skip push and create MR
      assert {:ok, @ref} =
               Gitlab.open("feature/x", "t", "d", %{})
    end
  end

  describe "get/1" do
    test "200: returns the task-domain view of the MR" do
      stub(fn conn ->
        assert conn.method == "GET"

        cond do
          conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "approved" => true,
              "web_url" => "https://gitlab.com/grp/proj/-/merge_requests/42"
            })

          # get/1 also polls the MR's pipelines for CI status.
          conn.request_path == "#{base_path()}/#{@iid}/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok,
              %{
                ref: @ref,
                status: :open,
                approved: true,
                url: "https://gitlab.com/grp/proj/-/merge_requests/42"
              }} = Gitlab.get(@ref)
    end

    test "maps merged/closed/locked states and absent approval" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
      end)

      assert {:ok, %{status: :merged, approved: false}} = Gitlab.get(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Not found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} = Gitlab.get(@ref)
    end

    test "includes pipeline status from the /pipelines endpoint" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 1, "status" => "failed"}])
        end
      end)

      assert {:ok, %{pipeline: :failed}} = Gitlab.get(@ref)
    end

    test "pipeline is :success when the latest pipeline succeeded" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 2, "status" => "success"}])
        end
      end)

      assert {:ok, %{pipeline: :success}} = Gitlab.get(@ref)
    end

    test "pipeline is :running when the latest pipeline is running" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 3, "status" => "running"}])
        end
      end)

      assert {:ok, %{pipeline: :running}} = Gitlab.get(@ref)
    end

    test "pipeline is nil when no pipelines exist" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([])
        end
      end)

      assert {:ok, %{pipeline: nil}} = Gitlab.get(@ref)
    end
  end

  # #354 Phase 1: get/1 classifies *why* an open MR can't merge so the Warden
  # (Watchdog) can escalate a blocked merge instead of parking it silently.
  describe "get/1 block_reason (#354)" do
    defp block_get(mr_fields, pipelines \\ []) do
      mr = Map.merge(%{"iid" => @iid, "state" => "opened"}, mr_fields)

      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(mr)

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pipelines)
        end
      end)

      {:ok, result} = Gitlab.get(@ref)
      result
    end

    test "mergeable MR has no block reason" do
      assert block_get(%{"detailed_merge_status" => "mergeable"}).block_reason == nil
    end

    test "has_conflicts classifies as :conflict" do
      assert block_get(%{"has_conflicts" => true}).block_reason == :conflict
    end

    test "detailed_merge_status conflict classifies as :conflict" do
      assert block_get(%{"detailed_merge_status" => "conflict"}).block_reason == :conflict
    end

    test "need_rebase classifies as :behind_base" do
      assert block_get(%{"detailed_merge_status" => "need_rebase"}).block_reason == :behind_base
    end

    test "ci_must_pass is non-blocking (CI required but not yet failed)" do
      # ci_must_pass means CI hasn't gone green yet — it may still be running.
      # Only a resolved :failed pipeline is a CI block, so this is nil.
      assert block_get(%{"detailed_merge_status" => "ci_must_pass"}).block_reason == nil
    end

    test "ci_still_running is non-blocking (pipeline in progress, not failed)" do
      assert block_get(%{"detailed_merge_status" => "ci_still_running"}).block_reason == nil
    end

    test "ci_must_pass with a failed pipeline still classifies as :ci_failed" do
      # When CI has actually failed, the resolved pipeline value wins regardless
      # of the detailed-status string.
      result =
        block_get(%{"detailed_merge_status" => "ci_must_pass"}, [
          %{"id" => 9, "status" => "failed"}
        ])

      assert result.block_reason == :ci_failed
    end

    test "transient detailed statuses (preparing/checking/unchecked) are non-blocking" do
      for status <- ["preparing", "checking", "unchecked"] do
        assert block_get(%{"detailed_merge_status" => status}).block_reason == nil,
               "expected #{status} to be non-blocking"
      end
    end

    test "a failed pipeline classifies as :ci_failed" do
      result = block_get(%{}, [%{"id" => 9, "status" => "failed"}])
      assert result.block_reason == :ci_failed
    end

    test "not_approved classifies as :needs_approval" do
      assert block_get(%{"detailed_merge_status" => "not_approved"}).block_reason ==
               :needs_approval
    end

    test "draft classifies as :draft" do
      assert block_get(%{"draft" => true}).block_reason == :draft
    end

    test "cannot_be_merged without detail falls back to :conflict" do
      assert block_get(%{"merge_status" => "cannot_be_merged"}).block_reason == :conflict
    end

    test "an unresolved-discussions status classifies as :blocked_other" do
      assert block_get(%{"detailed_merge_status" => "discussions_not_resolved"}).block_reason ==
               :blocked_other
    end

    test "a merged MR carries no block reason" do
      assert block_get(%{"state" => "merged"}).block_reason == nil
    end
  end

  describe "merge/1" do
    test "200: PUTs the merge endpoint and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}/merge"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
      end)

      assert :ok = Gitlab.merge(@ref)
    end

    test "405: not mergeable returns {:error, %Error{kind: :conflict}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(405)
        |> Req.Test.json(%{"message" => "405 Method Not Allowed"})
      end)

      assert {:error, %Error{kind: :conflict, status: 405}} = Gitlab.merge(@ref)
    end
  end

  describe "close/1" do
    test "PUTs state_event=close and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"state_event" => "close"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "closed"})
      end)

      assert :ok = Gitlab.close(@ref)
    end
  end

  describe "add_comment/2" do
    test "POSTs a note and returns :ok" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "#{base_path()}/#{@iid}/notes"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "looks good"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 99})
      end)

      assert :ok = Gitlab.add_comment(@ref, "looks good")
    end
  end

  describe "request_review/2" do
    test "PUTs reviewer_ids and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"reviewer_ids" => [3, 4]}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      assert :ok = Gitlab.request_review(@ref, [3, 4])
    end
  end

  describe "link_for/1" do
    test "builds a best-effort MR URL from host and project_id" do
      assert Gitlab.link_for(@ref) == "https://gitlab.com/12345/-/merge_requests/42"
    end

    test "returns \"\" when config is missing" do
      Config.clear()
      assert Gitlab.link_for(@ref) == ""
    end
  end

  describe "submit_review/4" do
    @approve_path "/api/v4/projects/12345/merge_requests/42/approve"
    @notes_path "/api/v4/projects/12345/merge_requests/42/notes"
    @unapprove_path "/api/v4/projects/12345/merge_requests/42/unapprove"

    test ":approve posts to /approve then posts an Approved summary note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"approved" => true})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "Approved"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved: no findings.", %{})
    end

    test ":request_changes unapproves and posts a Requesting changes note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @unapprove_path} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "Requesting changes"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 2})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :request_changes, "Fix these.", %{})
    end

    test "422 self-approve on :approve falls back to a VERDICT note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "You are not allowed to approve this merge request."
            })

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "VERDICT: APPROVE"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 3})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end

    test "401 with author-approval message on :approve falls back to a VERDICT note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"message" => "Author cannot approve own merge request."})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "VERDICT: APPROVE"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end

    test "422 with an unrelated message on :approve is not swallowed" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"message" => "Approvals are not configured for this project."})
        end
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end
  end

  describe "parse_ref/1" do
    test "accepts the !iid shorthand" do
      assert {:ok, "!42"} = Gitlab.parse_ref("!42")
    end

    test "accepts a bare integer (binary and integer)" do
      assert {:ok, "!42"} = Gitlab.parse_ref("42")
      assert {:ok, "!42"} = Gitlab.parse_ref(42)
    end

    test "accepts a full GitLab MR URL" do
      assert {:ok, "!42"} =
               Gitlab.parse_ref("https://gitlab.com/grp/proj/-/merge_requests/42")
    end

    test "rejects nonsense" do
      assert :error = Gitlab.parse_ref("not-a-ref")
      assert :error = Gitlab.parse_ref("!")
      assert :error = Gitlab.parse_ref(%{})
    end
  end

  describe "config_missing" do
    test "every callback returns {:error, %Error{kind: :config_missing}} with no active config" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Gitlab.open("b", "t", "d", %{})
      assert {:error, %Error{kind: :config_missing}} = Gitlab.get(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.merge(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.close(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.add_comment(@ref, "x")
      assert {:error, %Error{kind: :config_missing}} = Gitlab.request_review(@ref, [1])
    end

    test "missing credentials env var surfaces as config_missing" do
      System.delete_env(@env_var)

      assert {:error, %Error{kind: :config_missing, message: msg}} =
               Gitlab.open("b", "t", "d", %{})

      assert msg =~ @env_var
    end
  end
end
