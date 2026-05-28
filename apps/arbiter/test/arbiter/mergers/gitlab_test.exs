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
