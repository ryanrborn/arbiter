defmodule GtElixir.Trackers.JiraTest do
  use ExUnit.Case, async: false

  alias GtElixir.Trackers.Jira
  alias GtElixir.Trackers.Jira.{Config, Error}

  @host "leotechnologies.atlassian.net"
  @project "VR"
  @ref "VR-17585"
  @env_var "GTE_JIRA_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-jira-token")

    Config.put_active(%{
      "host" => @host,
      "project_key" => @project,
      "credentials_ref" => "env:#{@env_var}",
      "email" => "tester@example.com",
      "status_map" => %{
        "open" => "To Do",
        "in_progress" => "In Progress",
        "closed" => "Approved and merged"
      },
      "field_ids" => %{
        "title" => "summary",
        "description" => "description",
        "qa_notes" => "customfield_10300",
        "deployment_notes" => "customfield_10400"
      }
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(GtElixir.Trackers.Jira.HTTP, fun)

  describe "fetch/1" do
    test "200: returns the parsed Jira issue map" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}"
        assert ["Basic " <> _] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "key" => @ref,
          "fields" => %{"summary" => "Fix the thing", "status" => %{"name" => "In Progress"}}
        })
      end)

      assert {:ok, %{"key" => @ref, "fields" => %{"summary" => "Fix the thing"}}} =
               Jira.fetch(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"errorMessages" => ["Issue does not exist"]})
      end)

      assert {:error, %Error{kind: :not_found, status: 404, message: "Issue does not exist"}} =
               Jira.fetch(@ref)
    end

    test "401: returns {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"errorMessages" => ["Unauthorized"]})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} = Jira.fetch(@ref)
    end

    test "500: returns {:error, %Error{kind: :server_error}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "down"})
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} = Jira.fetch(@ref)
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Jira.fetch(@ref)
    end
  end

  describe "transition/2" do
    test "looks up transitions, finds matching name, POSTs the id" do
      Req.Test.stub(GtElixir.Trackers.Jira.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/rest/api/3/issue/" <> _} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{"id" => "11", "name" => "To Do"},
                %{"id" => "21", "name" => "In Progress"},
                %{"id" => "31", "name" => "Approved and merged"}
              ]
            })

          {"POST", "/rest/api/3/issue/" <> _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body) == %{"transition" => %{"id" => "31"}}

            conn
            |> Plug.Conn.put_status(204)
            |> Req.Test.json(%{})
        end
      end)

      assert :ok = Jira.transition(@ref, :closed)
    end

    test "returns {:error, :transition_not_found} when the bead status has no mapping" do
      Config.put_active(%{
        "host" => @host,
        "project_key" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "email" => "tester@example.com",
        # Empty status_map (only inherits defaults). Override :closed to empty
        # to force the not-found path.
        "status_map" => %{
          "open" => "To Do",
          "in_progress" => "In Progress",
          "closed" => ""
        }
      })

      assert {:error, %Error{kind: :transition_not_found}} = Jira.transition(@ref, :closed)
    end

    test "returns {:error, :transition_not_found} when the named transition is not available" do
      stub(fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "transitions" => [
            %{"id" => "11", "name" => "To Do"},
            %{"id" => "21", "name" => "In Progress"}
          ]
        })
      end)

      assert {:error, %Error{kind: :transition_not_found, message: msg}} =
               Jira.transition(@ref, :closed)

      assert msg =~ "Approved and merged"
    end
  end

  describe "update_fields/2" do
    test "PATCH-equivalent (PUT) with translated field IDs; markdown becomes ADF" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Translated keys
        assert Map.has_key?(decoded["fields"], "summary")
        assert Map.has_key?(decoded["fields"], "customfield_10300")

        # Title is a plain string (not ADF)
        assert decoded["fields"]["summary"] == "New title"

        # QA notes converted to ADF
        adf = decoded["fields"]["customfield_10300"]
        assert adf["type"] == "doc"
        assert adf["version"] == 1
        assert is_list(adf["content"])

        conn
        |> Plug.Conn.put_status(204)
        |> Req.Test.json(%{})
      end)

      assert :ok =
               Jira.update_fields(@ref, %{
                 title: "New title",
                 qa_notes: "## QA Steps\n\n- visit /foo\n- click *Save*"
               })
    end

    test "passes raw customfield_* keys through untouched" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["fields"]["customfield_99999"] == "literal value"

        conn
        |> Plug.Conn.put_status(204)
        |> Req.Test.json(%{})
      end)

      assert :ok = Jira.update_fields(@ref, %{"customfield_99999" => "literal value"})
    end

    test "422: returns validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"errorMessages" => ["Bad field"]})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Jira.update_fields(@ref, %{title: "x"})
    end
  end

  describe "link_for/1" do
    test "builds the browse URL from the active workspace host" do
      assert Jira.link_for(@ref) == "https://#{@host}/browse/#{@ref}"
    end

    test "falls back to a placeholder host when no workspace is set" do
      Config.clear()
      assert Jira.link_for(@ref) =~ "/browse/#{@ref}"
    end
  end

  describe "parse_ref/1" do
    test "accepts \"VR-17585\" when project_key matches the active workspace" do
      assert Jira.parse_ref(@ref) == {:ok, @ref}
    end

    test "rejects bare keys whose project_key doesn't match the workspace" do
      assert Jira.parse_ref("XX-1") == :error
    end

    test "accepts the \"jira:\" prefix even when project_key would mismatch" do
      assert Jira.parse_ref("jira:XX-1") == {:ok, "XX-1"}
    end

    test "extracts the key from a full Atlassian URL" do
      url = "https://leotechnologies.atlassian.net/browse/VR-17585"
      assert Jira.parse_ref(url) == {:ok, "VR-17585"}
    end

    test "returns :error for unrecognised strings" do
      assert Jira.parse_ref("not a ref") == :error
      assert Jira.parse_ref("") == :error
    end

    test "returns :error for non-string input" do
      assert Jira.parse_ref(nil) == :error
      assert Jira.parse_ref(42) == :error
    end
  end

  describe "list_transitions/1" do
    test "parses the transitions response and maps to bead-status atoms" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}/transitions"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "transitions" => [
            %{"id" => "11", "name" => "To Do"},
            %{"id" => "21", "name" => "In Progress"},
            %{"id" => "31", "name" => "Approved and merged"},
            # Names without a mapping in status_map are dropped.
            %{"id" => "41", "name" => "Some Unmapped Status"}
          ]
        })
      end)

      assert {:ok, atoms} = Jira.list_transitions(@ref)
      assert :open in atoms
      assert :in_progress in atoms
      assert :closed in atoms
      assert length(atoms) == 3
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:jira) resolves to this adapter (no raise)" do
      assert GtElixir.Trackers.for_type(:jira) == Jira
    end
  end

  describe "with_workspace/2" do
    test "scopes config to the block and restores afterwards" do
      Config.clear()

      result =
        Jira.with_workspace(
          %{
            "host" => "other.example.com",
            "project_key" => "OT",
            "credentials_ref" => "env:#{@env_var}",
            "email" => "scoped@example.com"
          },
          fn -> Jira.link_for("OT-7") end
        )

      assert result == "https://other.example.com/browse/OT-7"
      # After the block, config is cleared.
      assert {:error, %Error{kind: :config_missing}} = Jira.fetch("OT-1")
    end
  end
end
