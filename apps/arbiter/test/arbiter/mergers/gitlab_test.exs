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

    test "when repo_path is provided: pushes the branch before creating the MR" do
      tmp_dir = System.tmp_dir!()
      repo_dir = Path.join(tmp_dir, "test_gitlab_push_#{System.unique_integer()}")

      # Setup: create a minimal git repo and branch
      File.mkdir_p!(repo_dir)

      System.cmd("git", ["init"], cd: repo_dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_dir)
      System.cmd("git", ["config", "user.name", "Test User"], cd: repo_dir)
      System.cmd("git", ["config", "user.signingkey", ""], cd: repo_dir)
      System.cmd("git", ["commit", "--allow-empty", "-m", "initial"], cd: repo_dir)

      # Mock a remote origin
      remote_dir = Path.join(tmp_dir, "remote_#{System.unique_integer()}.git")
      File.mkdir_p!(remote_dir)
      System.cmd("git", ["init", "--bare"], cd: remote_dir)
      System.cmd("git", ["remote", "add", "origin", remote_dir], cd: repo_dir)

      System.cmd("git", ["checkout", "-b", "feature/test-branch"], cd: repo_dir)

      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == base_path()

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      # Call open with repo_path — should push the branch before POST
      assert {:ok, @ref} =
               Gitlab.open("feature/test-branch", "Test push", "desc", %{
                 repo_path: repo_dir
               })

      # Verify the branch was pushed to the remote
      {:ok, branches_output} =
        case System.cmd("git", ["branch", "-r"], cd: remote_dir) do
          {output, 0} -> {:ok, output}
          {output, _} -> {:error, output}
        end

      assert String.contains?(branches_output, "feature/test-branch")
    after
      # Cleanup
      tmp_dir = System.tmp_dir!()
      File.rm_rf(Path.join(tmp_dir, "test_gitlab_push_*"))
      File.rm_rf(Path.join(tmp_dir, "remote_*.git"))
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
    test "200: returns the bead-domain view of the MR" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "#{base_path()}/#{@iid}"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "iid" => @iid,
          "state" => "opened",
          "approved" => true,
          "web_url" => "https://gitlab.com/grp/proj/-/merge_requests/42"
        })
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
