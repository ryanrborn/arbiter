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

  describe "create/1" do
    defp issues_path, do: "/repos/#{@owner}/#{@repo}/issues"

    test "POSTs title+body and returns the bare-number ref from the response" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == issues_path()
        assert ["Bearer test-github-token"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "Fix the thing"
        assert decoded["body"] == "Some markdown\n\n- one\n- two"
        # No status passed → no labels seeded.
        refute Map.has_key?(decoded, "labels")
        refute Map.has_key?(decoded, "assignees")

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 99, "title" => "Fix the thing"})
      end)

      assert {:ok, "99"} =
               GitHub.create(%{
                 title: "Fix the thing",
                 description: "Some markdown\n\n- one\n- two"
               })
    end

    test "missing :description still POSTs (body defaults to empty string)" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "minimal"
        assert decoded["body"] == ""

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 7})
      end)

      assert {:ok, "7"} = GitHub.create(%{title: "minimal"})
    end

    test "seeds the in-progress label when :status is :in_progress" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["labels"] == ["in progress"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 12})
      end)

      assert {:ok, "12"} =
               GitHub.create(%{title: "wip", description: "", status: :in_progress})
    end

    test "honours a workspace status_map label override" do
      Config.put_active(%{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "in_progress" => %{"state" => "open", "label" => "wip"}
        }
      })

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["labels"] == ["wip"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 13})
      end)

      assert {:ok, "13"} = GitHub.create(%{title: "wip", status: :in_progress})
    end

    test "open status doesn't add a labels field (default open is label=nil)" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "labels")

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 14})
      end)

      assert {:ok, "14"} = GitHub.create(%{title: "fresh", status: :open})
    end

    test "passes :assignee through as a one-element assignees list" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["assignees"] == ["octocat"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 15})
      end)

      assert {:ok, "15"} = GitHub.create(%{title: "owned", assignee: "octocat"})
    end

    test "missing :title returns validation_failed without making a request" do
      # No stub registered — if create/1 made the request anyway the test
      # would crash on the unexpected call rather than silently passing.
      assert {:error, %Error{kind: :validation_failed, message: msg}} =
               GitHub.create(%{description: "no title"})

      assert msg =~ ":title"
    end

    test "blank :title returns validation_failed" do
      assert {:error, %Error{kind: :validation_failed}} = GitHub.create(%{title: ""})
    end

    test "422 from GitHub surfaces as validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               GitHub.create(%{title: "boom"})
    end

    test "201 with no \"number\" surfaces as validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"title" => "weird"})
      end)

      assert {:error, %Error{kind: :validation_failed, message: msg}} =
               GitHub.create(%{title: "weird"})

      assert msg =~ "number"
    end

    test "missing config returns config_missing" do
      Config.clear()
      assert {:error, %Error{kind: :config_missing}} = GitHub.create(%{title: "x"})
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:github) resolves to this adapter (no raise)" do
      assert Arbiter.Trackers.for_type(:github) == GitHub
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
