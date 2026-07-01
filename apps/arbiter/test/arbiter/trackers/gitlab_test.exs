defmodule Arbiter.Trackers.GitlabTest do
  use ExUnit.Case, async: false

  alias Arbiter.Trackers.Gitlab
  alias Arbiter.Trackers.Gitlab.{Config, Error}

  @host "gitlab.com"
  @project "12345"
  @ref "42"
  @env_var "GTE_GITLAB_TRACKER_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => @host,
      "project_id" => @project,
      "credentials_ref" => "env:#{@env_var}"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.Gitlab.HTTP, fun)

  defp issue_path, do: "/api/v4/projects/#{@project}/issues/#{@ref}"
  defp issues_path, do: "/api/v4/projects/#{@project}/issues"

  describe "fetch/1" do
    test "200: returns the parsed issue map and sends PRIVATE-TOKEN auth" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == issue_path()
        assert ["test-gitlab-token"] = Plug.Conn.get_req_header(conn, "private-token")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => 42, "title" => "Fix the thing", "state" => "opened"})
      end)

      assert {:ok, %{"iid" => 42, "title" => "Fix the thing"}} = Gitlab.fetch(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Not found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} = Gitlab.fetch(@ref)
    end

    test "401: returns {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "401 Unauthorized"})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} = Gitlab.fetch(@ref)
    end

    test "503: returns {:error, %Error{kind: :server_error}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "down"})
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} = Gitlab.fetch(@ref)
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Gitlab.fetch(@ref)
    end

    test "missing env token returns {:error, %Error{kind: :config_missing}}" do
      System.delete_env(@env_var)

      assert {:error, %Error{kind: :config_missing}} = Gitlab.fetch(@ref)
    end
  end

  describe "transition/2" do
    test "to :closed PUTs state_event=close and strips managed labels, keeping others" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => 42,
              "state" => "opened",
              "labels" => ["in progress", "bug"]
            })

          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state_event"] == "close"
            # "in progress" (managed) stripped; "bug" (unrelated) preserved.
            assert decoded["labels"] == "bug"

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "closed"})
        end
      end)

      assert :ok = Gitlab.transition(@ref, :closed)
    end

    test "to :in_progress keeps the issue opened and adds the in-progress label" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "opened", "labels" => ["bug"]})

          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            refute Map.has_key?(decoded, "state_event")
            assert Enum.sort(String.split(decoded["labels"], ",")) == ["bug", "in progress"]

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42})
        end
      end)

      assert :ok = Gitlab.transition(@ref, :in_progress)
    end

    test "to :open reopens and removes a lingering in-progress label" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "closed", "labels" => ["in progress"]})

          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state_event"] == "reopen"
            assert decoded["labels"] == ""

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "opened"})
        end
      end)

      assert :ok = Gitlab.transition(@ref, :open)
    end

    test "honours a workspace status_map override" do
      Config.put_active(%{
        "host" => @host,
        "project_id" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "in_progress" => %{"state" => "opened", "label" => "wip"},
          "closed" => %{"state" => "closed", "label" => "shipped"}
        }
      })

      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "opened", "labels" => ["wip"]})

          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state_event"] == "close"
            # "wip" (managed in_progress label) stripped, "shipped" added.
            assert decoded["labels"] == "shipped"

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42})
        end
      end)

      assert :ok = Gitlab.transition(@ref, :closed)
    end

    test "propagates a fetch failure without PUTting" do
      stub(fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Not found"})
      end)

      assert {:error, %Error{kind: :not_found}} = Gitlab.transition(@ref, :closed)
    end

    test "to :closed is a no-op when the issue is already closed (idempotent)" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => 42, "state" => "closed", "labels" => ["bug"]})

          "PUT" ->
            flunk("must not PUT when issue is already closed")
        end
      end)

      assert :ok = Gitlab.transition(@ref, :closed)
    end

    test "to :in_progress is a no-op when already opened with the in-progress label" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => 42,
              "state" => "opened",
              "labels" => ["in progress", "bug"]
            })

          "PUT" ->
            flunk("must not PUT when issue is already in the target state")
        end
      end)

      assert :ok = Gitlab.transition(@ref, :in_progress)
    end
  end

  describe "update_fields/2" do
    test "translates title -> title and description -> description, PUTs the issue" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == issue_path()

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "New title"
        assert decoded["description"] == "New body"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => 42})
      end)

      assert :ok = Gitlab.update_fields(@ref, %{title: "New title", description: "New body"})
    end

    test "drops unknown fields" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"title" => "Only this"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => 42})
      end)

      assert :ok = Gitlab.update_fields(@ref, %{title: "Only this", bogus_field: "ignored"})
    end

    test "is a no-op when no known fields are present (no request)" do
      stub(fn _conn -> flunk("must not issue a request when nothing to update") end)

      assert :ok = Gitlab.update_fields(@ref, %{bogus_field: "ignored"})
    end

    test "422: returns validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "validation failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Gitlab.update_fields(@ref, %{title: "x"})
    end
  end

  describe "create/1" do
    test "POSTs the issue and returns the new iid as the ref" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == issues_path()

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "Wire the thing"
        assert decoded["description"] == "Details here"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => 77, "title" => "Wire the thing"})
      end)

      assert {:ok, "77"} =
               Gitlab.create(%{title: "Wire the thing", description: "Details here"})
    end

    test "merges status/priority/type labels into a comma-joined labels string" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        labels = String.split(decoded["labels"], ",")
        # :in_progress default status label + priority + type
        assert "in progress" in labels
        assert "priority: 1" in labels
        assert "type: bug" in labels

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => 78})
      end)

      assert {:ok, "78"} =
               Gitlab.create(%{
                 title: "Labelled",
                 status: :in_progress,
                 priority: 1,
                 issue_type: "bug"
               })
    end

    test "resolves an assignee username to a numeric id via /users" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/users"} ->
            assert URI.decode_query(conn.query_string)["username"] == "alice"
            Req.Test.json(conn, [%{"id" => 9, "username" => "alice"}])

          {"POST", _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["assignee_ids"] == [9]

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"iid" => 79})
        end
      end)

      assert {:ok, "79"} = Gitlab.create(%{title: "Assigned", assignee: "alice"})
    end

    test "missing title returns validation_failed" do
      assert {:error, %Error{kind: :validation_failed}} =
               Gitlab.create(%{description: "no title"})
    end
  end

  describe "link_for/1" do
    test "builds the gitlab issue URL from the active host/project" do
      assert Gitlab.link_for(@ref) == "https://#{@host}/#{@project}/-/issues/#{@ref}"
    end

    test "falls back to placeholders when no workspace is active" do
      Config.clear()
      assert Gitlab.link_for("7") == "https://gitlab.com/group/project/-/issues/7"
    end
  end

  describe "parse_ref/1" do
    test "accepts the \"gitlab:\" prefix" do
      assert Gitlab.parse_ref("gitlab:42") == {:ok, "42"}
    end

    test "accepts the \"gl-\" prefix" do
      assert Gitlab.parse_ref("gl-42") == {:ok, "42"}
    end

    test "accepts the \"#\" prefix" do
      assert Gitlab.parse_ref("#42") == {:ok, "42"}
    end

    test "accepts a bare integer string" do
      assert Gitlab.parse_ref("42") == {:ok, "42"}
    end

    test "extracts the iid from a full gitlab issue URL" do
      url = "https://gitlab.com/group/project/-/issues/42"
      assert Gitlab.parse_ref(url) == {:ok, "42"}
    end

    test "returns :error for unrecognised strings" do
      assert Gitlab.parse_ref("not a ref") == :error
      assert Gitlab.parse_ref("") == :error
      assert Gitlab.parse_ref("gl-abc") == :error
      assert Gitlab.parse_ref("gitlab:0") == :error
    end

    test "returns :error for non-string input" do
      assert Gitlab.parse_ref(nil) == :error
      assert Gitlab.parse_ref(42) == :error
    end
  end

  describe "list_transitions/1" do
    test "validates the ref and returns the configured task statuses" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == issue_path()

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => 42, "state" => "opened"})
      end)

      assert {:ok, atoms} = Gitlab.list_transitions(@ref)
      assert Enum.sort(atoms) == [:closed, :in_progress, :open]
    end

    test "propagates a fetch failure" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Not found"})
      end)

      assert {:error, %Error{kind: :not_found}} = Gitlab.list_transitions(@ref)
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:gitlab) resolves to this adapter (no raise)" do
      assert Arbiter.Trackers.for_type(:gitlab) == Gitlab
    end
  end

  describe "list_open/1" do
    test "fetches /user for viewer, then assigned open issues, returns normalized summaries" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/user"} ->
            Req.Test.json(conn, %{"id" => 1, "username" => "me"})

          {"GET", path} ->
            assert path == issues_path()
            assert URI.decode_query(conn.query_string)["assignee_username"] == "me"
            assert URI.decode_query(conn.query_string)["state"] == "opened"

            Req.Test.json(conn, [
              %{
                "iid" => 42,
                "title" => "First",
                "state" => "opened",
                "web_url" => "https://gitlab.com/x/y/-/issues/42",
                "assignees" => [%{"username" => "me"}]
              },
              %{
                "iid" => 43,
                "title" => "Second",
                "state" => "opened",
                "web_url" => "https://gitlab.com/x/y/-/issues/43",
                "labels" => ["in progress"],
                "assignees" => [%{"username" => "me"}]
              }
            ])
        end
      end)

      assert {:ok, [first, second]} = Gitlab.list_open([])

      assert first.ref == "42"
      assert first.title == "First"
      assert first.url == "https://gitlab.com/x/y/-/issues/42"
      assert first.status == :open
      assert first.assignees == ["me"]
      assert is_map(first.raw)

      assert second.ref == "43"
      assert second.status == :in_progress
    end

    test "follows the x-next-page header across pages" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/user"} ->
            Req.Test.json(conn, %{"id" => 1, "username" => "me"})

          {"GET", _} ->
            page = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

            case page do
              0 ->
                conn
                |> Plug.Conn.put_resp_header("x-next-page", "2")
                |> Plug.Conn.put_status(200)
                |> Req.Test.json([%{"iid" => 1, "title" => "p1", "state" => "opened"}])

              _ ->
                assert URI.decode_query(conn.query_string)["page"] == "2"

                conn
                |> Plug.Conn.put_status(200)
                |> Req.Test.json([%{"iid" => 2, "title" => "p2", "state" => "opened"}])
            end
        end
      end)

      assert {:ok, [a, b]} = Gitlab.list_open([])
      assert a.ref == "1"
      assert b.ref == "2"
    end

    test "accepts an explicit :assignee username (no /user call)" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/user"} ->
            flunk("must not call /user when :assignee is explicit")

          {"GET", _} ->
            assert URI.decode_query(conn.query_string)["assignee_username"] == "bob"
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, []} = Gitlab.list_open(assignee: "bob")
    end
  end

  describe "add_comment/2" do
    test "POSTs a note on the issue" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == issue_path() <> "/notes"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "hello"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 1})
      end)

      assert :ok = Gitlab.add_comment(@ref, "hello")
    end
  end

  describe "current_user/0 and assignees/1" do
    test "current_user returns the token's username" do
      stub(fn conn ->
        assert conn.request_path == "/api/v4/user"
        Req.Test.json(conn, %{"id" => 5, "username" => "octocat"})
      end)

      assert {:ok, "octocat"} = Gitlab.current_user()
    end

    test "assignees extracts usernames from the assignees list" do
      assert Gitlab.assignees(%{"assignees" => [%{"username" => "a"}, %{"username" => "b"}]}) ==
               ["a", "b"]
    end

    test "assignees tolerates the legacy single-assignee shape" do
      assert Gitlab.assignees(%{"assignee" => %{"username" => "solo"}}) == ["solo"]
    end

    test "assignees returns [] when unassigned" do
      assert Gitlab.assignees(%{}) == []
    end
  end

  describe "raw-issue extractors" do
    test "issue_status maps state to task vocabulary" do
      assert Gitlab.issue_status(%{"state" => "closed"}) == :closed
      assert Gitlab.issue_status(%{"state" => "opened"}) == :open
    end

    test "extract_title / extract_description" do
      assert Gitlab.extract_title(%{"title" => "T"}) == "T"
      assert Gitlab.extract_title(%{}) == "(no title)"
      assert Gitlab.extract_description(%{"description" => "D"}) == "D"
      assert Gitlab.extract_description(%{}) == ""
    end

    test "extract_priority / extract_difficulty parse string labels" do
      assert Gitlab.extract_priority(%{"labels" => ["priority: 3", "bug"]}) == {:ok, 3}
      assert Gitlab.extract_priority(%{"labels" => ["bug"]}) == nil
      assert Gitlab.extract_difficulty(%{"labels" => ["difficulty: 2"]}) == {:ok, 2}
      assert Gitlab.extract_difficulty(%{"labels" => []}) == nil
    end
  end

  describe "check_prior_claim/1" do
    test "returns :ok when no ownership marker is present" do
      stub(fn conn ->
        assert conn.request_path == issue_path() <> "/notes"
        Req.Test.json(conn, [%{"body" => "just a normal comment"}])
      end)

      assert :ok = Gitlab.check_prior_claim(@ref)
    end

    test "returns {:already_claimed, body} when a marker is found" do
      stub(fn conn ->
        Req.Test.json(conn, [%{"body" => "Claimed as bd-1. Arbiter installation: host-x."}])
      end)

      assert {:error, {:already_claimed, body}} = Gitlab.check_prior_claim(@ref)
      assert body =~ "Arbiter installation:"
    end
  end

  describe "signal_claim/3" do
    test "posts an ownership note and assigns the viewer" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", path} ->
            assert path == issue_path() <> "/notes"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "Arbiter installation:"
            Req.Test.json(conn |> Plug.Conn.put_status(201), %{"id" => 1})

          {"GET", "/api/v4/users"} ->
            Req.Test.json(conn, [%{"id" => 3, "username" => "me"}])

          {"PUT", path} ->
            assert path == issue_path()
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["assignee_ids"] == [3]
            Req.Test.json(conn, %{"iid" => 42})
        end
      end)

      assert :ok =
               Gitlab.signal_claim(@ref, "bd-1", %{
                 workspace_name: "ws",
                 workspace_prefix: "bd",
                 current_user: "me",
                 host: "host-x"
               })
    end
  end

  describe "search_by_title/1" do
    test "returns exact (case-insensitive) title matches as summaries" do
      stub(fn conn ->
        assert conn.request_path == issues_path()
        q = URI.decode_query(conn.query_string)
        assert q["search"] == "Wire the thing"
        assert q["in"] == "title"
        assert q["state"] == "opened"

        Req.Test.json(conn, [
          %{"iid" => 42, "title" => "wire the thing", "web_url" => "u1"},
          %{"iid" => 43, "title" => "something else", "web_url" => "u2"}
        ])
      end)

      assert {:ok, [match]} = Gitlab.search_by_title("Wire the thing")
      assert match.ref == "42"
    end

    test "returns [] when nothing matches" do
      stub(fn conn -> Req.Test.json(conn, []) end)
      assert {:ok, []} = Gitlab.search_by_title("nope")
    end
  end
end
