defmodule Arbiter.Trackers.GitHubTest do
  use ExUnit.Case, async: false

  alias Arbiter.Trackers.GitHub
  alias Arbiter.Trackers.GitHub.{Config, Error}

  @owner "ryanrborn"
  @repo "arbiter"
  @ref "42"
  @env_var "GTE_GITHUB_TRACKER_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")

    Config.put_active(%{
      "owner" => @owner,
      "repo" => @repo,
      "credentials_ref" => "env:#{@env_var}"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

  defp issue_path, do: "/repos/#{@owner}/#{@repo}/issues/#{@ref}"

  describe "fetch/1" do
    test "200: returns the parsed issue map and sends Bearer auth" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == issue_path()
        assert ["Bearer test-github-token"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 42, "title" => "Fix the thing", "state" => "open"})
      end)

      assert {:ok, %{"number" => 42, "title" => "Fix the thing"}} = GitHub.fetch(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404, message: "Not Found"}} =
               GitHub.fetch(@ref)
    end

    test "401: returns {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} = GitHub.fetch(@ref)
    end

    test "503: returns {:error, %Error{kind: :server_error}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "down"})
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} = GitHub.fetch(@ref)
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = GitHub.fetch(@ref)
    end

    test "missing env token returns {:error, %Error{kind: :config_missing}}" do
      System.delete_env(@env_var)

      assert {:error, %Error{kind: :config_missing}} = GitHub.fetch(@ref)
    end
  end

  describe "transition/2" do
    test "to :closed PATCHes state=closed and strips managed labels, keeping others" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 42,
              "state" => "open",
              "labels" => [%{"name" => "in progress"}, %{"name" => "bug"}]
            })

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state"] == "closed"
            # "in progress" (managed) stripped; "bug" (unrelated) preserved; no
            # closed-status label by default.
            assert decoded["labels"] == ["bug"]

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 42, "state" => "closed"})
        end
      end)

      assert :ok = GitHub.transition(@ref, :closed)
    end

    test "to :in_progress keeps the issue open and adds the in-progress label" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 42,
              "state" => "open",
              "labels" => [%{"name" => "bug"}]
            })

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state"] == "open"
            assert Enum.sort(decoded["labels"]) == ["bug", "in progress"]

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 42})
        end
      end)

      assert :ok = GitHub.transition(@ref, :in_progress)
    end

    test "to :open re-opens and removes a lingering in-progress label" do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 42,
              "state" => "closed",
              "labels" => [%{"name" => "in progress"}]
            })

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state"] == "open"
            assert decoded["labels"] == []

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 42, "state" => "open"})
        end
      end)

      assert :ok = GitHub.transition(@ref, :open)
    end

    test "honours a workspace status_map override" do
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "in_progress" => %{"state" => "open", "label" => "wip"},
          "closed" => %{"state" => "closed", "label" => "shipped"}
        }
      })

      stub(fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "number" => 42,
              "state" => "open",
              "labels" => [%{"name" => "wip"}]
            })

          "PATCH" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["state"] == "closed"
            # "wip" (managed in_progress label) stripped, "shipped" added.
            assert decoded["labels"] == ["shipped"]

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 42})
        end
      end)

      assert :ok = GitHub.transition(@ref, :closed)
    end

    test "propagates a fetch failure without PATCHing" do
      stub(fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found}} = GitHub.transition(@ref, :closed)
    end
  end

  describe "update_fields/2" do
    test "translates title -> title and description -> body, PATCHes the issue" do
      stub(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == issue_path()

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "New title"
        assert decoded["body"] == "New body"
        refute Map.has_key?(decoded, "description")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 42})
      end)

      assert :ok = GitHub.update_fields(@ref, %{title: "New title", description: "New body"})
    end

    test "drops unknown fields" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"title" => "Only this"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 42})
      end)

      assert :ok = GitHub.update_fields(@ref, %{title: "Only this", bogus_field: "ignored"})
    end

    test "422: returns validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               GitHub.update_fields(@ref, %{title: "x"})
    end
  end

  describe "link_for/1" do
    test "builds the github.com issue URL from the active owner/repo" do
      assert GitHub.link_for(@ref) == "https://github.com/#{@owner}/#{@repo}/issues/#{@ref}"
    end

    test "falls back to a placeholder slug when no workspace is active" do
      Config.clear()
      assert GitHub.link_for("7") == "https://github.com/owner/repo/issues/7"
    end
  end

  describe "parse_ref/1" do
    test "accepts the \"github:\" prefix" do
      assert GitHub.parse_ref("github:42") == {:ok, "42"}
    end

    test "accepts the \"gh-\" prefix" do
      assert GitHub.parse_ref("gh-42") == {:ok, "42"}
    end

    test "accepts the \"#\" prefix" do
      assert GitHub.parse_ref("#42") == {:ok, "42"}
    end

    test "accepts a bare integer string" do
      assert GitHub.parse_ref("42") == {:ok, "42"}
    end

    test "extracts the number from a full github.com issue URL" do
      url = "https://github.com/ryanrborn/arbiter/issues/42"
      assert GitHub.parse_ref(url) == {:ok, "42"}
    end

    test "returns :error for unrecognised strings" do
      assert GitHub.parse_ref("not a ref") == :error
      assert GitHub.parse_ref("") == :error
      assert GitHub.parse_ref("gh-abc") == :error
      assert GitHub.parse_ref("github:0") == :error
    end

    test "returns :error for non-string input" do
      assert GitHub.parse_ref(nil) == :error
      assert GitHub.parse_ref(42) == :error
    end
  end

  describe "list_transitions/1" do
    test "validates the ref and returns the configured bead statuses" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == issue_path()

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 42, "state" => "open"})
      end)

      assert {:ok, atoms} = GitHub.list_transitions(@ref)
      assert Enum.sort(atoms) == [:closed, :in_progress, :open]
    end

    test "propagates a fetch failure" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found}} = GitHub.list_transitions(@ref)
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:github) resolves to this adapter (no raise)" do
      assert Arbiter.Trackers.for_type(:github) == GitHub
    end
  end

  describe "list_open/1" do
    test "fetches /user for viewer login, then assigned open issues, returns normalized summaries" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => "me"})

          {"GET", "/repos/" <> _ = path} ->
            # The /issues list endpoint, not a specific issue.
            assert String.ends_with?(path, "/issues")
            assert URI.decode_query(conn.query_string)["assignee"] == "me"
            assert URI.decode_query(conn.query_string)["state"] == "open"

            Req.Test.json(conn, [
              %{
                "number" => 42,
                "title" => "First",
                "state" => "open",
                "html_url" => "https://github.com/x/y/issues/42",
                "assignees" => [%{"login" => "me"}]
              },
              %{
                "number" => 43,
                "title" => "Second",
                "state" => "open",
                "html_url" => "https://github.com/x/y/issues/43",
                "labels" => [%{"name" => "in progress"}],
                "assignees" => [%{"login" => "me"}]
              }
            ])
        end
      end)

      assert {:ok, [first, second]} = GitHub.list_open([])

      assert first.ref == "42"
      assert first.title == "First"
      assert first.url == "https://github.com/x/y/issues/42"
      assert first.status == :open
      assert first.assignees == ["me"]
      assert is_map(first.raw)

      assert second.ref == "43"
      assert second.status == :in_progress
    end

    test "filters out pull requests (they share the /issues endpoint)" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => "me"})

          {"GET", _} ->
            Req.Test.json(conn, [
              %{"number" => 42, "title" => "An issue", "state" => "open"},
              %{
                "number" => 43,
                "title" => "A PR",
                "state" => "open",
                "pull_request" => %{"url" => "..."}
              }
            ])
        end
      end)

      assert {:ok, [only]} = GitHub.list_open([])
      assert only.ref == "42"
    end

    test "follows the Link rel=\"next\" header across pages" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => "me"})

          {"GET", _} ->
            page = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

            case page do
              0 ->
                # Use a relative URL in the Link header; what matters is the
                # path + query, both of which our parser handles.
                conn
                |> Plug.Conn.put_resp_header(
                  "link",
                  ~s(</repos/#{@owner}/#{@repo}/issues?page=2>; rel="next")
                )
                |> Plug.Conn.put_status(200)
                |> Req.Test.json([%{"number" => 1, "title" => "p1", "state" => "open"}])

              1 ->
                Req.Test.json(conn, [%{"number" => 2, "title" => "p2", "state" => "open"}])
            end
        end
      end)

      assert {:ok, [a, b]} = GitHub.list_open([])
      assert a.ref == "1"
      assert b.ref == "2"
    end

    test "accepts an explicit assignee login (skips the viewer lookup)" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            flunk("should not look up /user when assignee is explicit")

          {"GET", _} ->
            assert URI.decode_query(conn.query_string)["assignee"] == "other"
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, []} = GitHub.list_open(assignee: "other")
    end

    test "propagates a missing-config error" do
      Config.clear()
      assert {:error, %Error{kind: :config_missing}} = GitHub.list_open([])
    end

    test "propagates an HTTP error from the issues endpoint" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => "me"})

          {"GET", _} ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"message" => "Bad credentials"})
        end
      end)

      assert {:error, %Error{kind: :unauthenticated}} = GitHub.list_open([])
    end
  end

  describe "create/1" do
    test "POSTs the body and returns the new issue number as a bare string ref" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/#{@owner}/#{@repo}/issues"
        assert ["Bearer test-github-token"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "Wire the thing"
        assert decoded["body"] == "Markdown description"
        # No assignee / no initial-status-label by default for :open status.
        refute Map.has_key?(decoded, "assignees")
        refute Map.has_key?(decoded, "labels")

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "number" => 99,
          "title" => "Wire the thing",
          "html_url" => "https://github.com/#{@owner}/#{@repo}/issues/99"
        })
      end)

      assert {:ok, "99"} =
               GitHub.create(%{title: "Wire the thing", description: "Markdown description"})
    end

    test "drops a blank description and propagates assignee + in_progress label" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "tagged"
        refute Map.has_key?(decoded, "body")
        assert decoded["assignees"] == ["alice"]
        assert decoded["labels"] == ["in progress"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 100})
      end)

      assert {:ok, "100"} =
               GitHub.create(%{
                 title: "tagged",
                 description: "",
                 assignee: "alice",
                 status: :in_progress
               })
    end

    test "422 from GitHub surfaces validation_failed without writing back a ref" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422, message: "Validation Failed"}} =
               GitHub.create(%{title: "boom"})
    end

    test "blank title is rejected before any HTTP call" do
      stub(fn _conn ->
        flunk("must not POST when title is blank")
      end)

      assert {:error, %Error{kind: :validation_failed, message: msg}} =
               GitHub.create(%{title: ""})

      assert msg =~ "title"
    end

    test "missing config returns config_missing" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = GitHub.create(%{title: "anything"})
    end

    test "honours a workspace status_map override for the initial label" do
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "open" => %{"state" => "open", "label" => "todo"}
        }
      })

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["labels"] == ["todo"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 101})
      end)

      assert {:ok, "101"} = GitHub.create(%{title: "with-label", status: :open})
    end

    test "maps :priority to a 'priority: N' label in the outbound request body" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "urgent work"
        assert "priority: 1" in decoded["labels"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 200})
      end)

      assert {:ok, "200"} = GitHub.create(%{title: "urgent work", priority: 1})
    end

    test "maps :issue_type to a 'type: T' label in the outbound request body" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "bug report"
        assert "type: bug" in decoded["labels"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 201})
      end)

      assert {:ok, "201"} = GitHub.create(%{title: "bug report", issue_type: "bug"})
    end

    test "merges priority, type, and status labels in a single 'labels' field" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        labels = decoded["labels"]
        assert "in progress" in labels
        assert "priority: 2" in labels
        assert "type: feature" in labels
        # All three present and no duplicates.
        assert length(labels) == 3

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 202})
      end)

      assert {:ok, "202"} =
               GitHub.create(%{
                 title: "combined",
                 status: :in_progress,
                 priority: 2,
                 issue_type: "feature"
               })
    end
  end

  describe "with_workspace/2" do
    test "scopes config to the block and restores afterwards" do
      Config.clear()

      result =
        GitHub.with_workspace(
          %{"owner" => "octo", "repo" => "widget", "credentials_ref" => "env:#{@env_var}"},
          fn -> GitHub.link_for("7") end
        )

      assert result == "https://github.com/octo/widget/issues/7"
      # After the block, config is cleared.
      assert {:error, %Error{kind: :config_missing}} = GitHub.fetch("1")
    end
  end
end
