defmodule Arbiter.Trackers.JiraTest do
  use ExUnit.Case, async: false

  alias Arbiter.Trackers.Jira
  alias Arbiter.Trackers.Jira.{Config, Error}

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
      # status_map now maps task lifecycle atoms -> target STATUS names (the
      # adapter path-finds the transitions to reach them).
      "status_map" => %{
        "open" => "To Do",
        "in_progress" => "In Progress",
        "closed" => "Done"
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

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fun)

  defp issue(key) do
    %{
      "key" => key,
      "fields" => %{
        "summary" => "Issue #{key}",
        "assignee" => %{"accountId" => "account-123"},
        "status" => %{"statusCategory" => %{"key" => "new"}}
      }
    }
  end

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

  describe "transition/2 (status-targeted)" do
    test "single-hop fast path: takes the live transition whose `to` is the target status" do
      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        case conn.method do
          "GET" ->
            assert String.ends_with?(conn.request_path, "/transitions")

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "111",
                  "name" => "Approved and not merged",
                  "to" => %{"name" => "Pending Merge"}
                },
                %{"id" => "61", "name" => "Approved and merged", "to" => %{"name" => "Done"}}
              ]
            })

          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            # Matched by destination status ("Done"), not transition name.
            assert Jason.decode!(body) == %{"transition" => %{"id" => "61"}}

            conn
            |> Plug.Conn.put_status(204)
            |> Req.Test.json(%{})
        end
      end)

      assert :ok = Jira.transition(@ref, :closed)
    end

    test "multi-hop: walks the configured graph, executing each hop in order" do
      {:ok, agent} = Agent.start_link(fn -> "Backlog" end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      Config.put_active(%{
        "host" => @host,
        "project_key" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "email" => "tester@example.com",
        "status_map" => %{"in_progress" => "In Progress"},
        "transition_graph" => %{
          "Backlog" => [%{"transition" => "To do next", "to" => "To Do"}],
          "To Do" => [%{"transition" => "Start work", "to" => "In Progress"}]
        }
      })

      transitions_for = fn
        "Backlog" -> [%{"id" => "141", "name" => "To do next", "to" => %{"name" => "To Do"}}]
        "To Do" -> [%{"id" => "200", "name" => "Start work", "to" => %{"name" => "In Progress"}}]
        _ -> []
      end

      advance = fn
        "141" -> "To Do"
        "200" -> "In Progress"
      end

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cur = Agent.get(agent, & &1)

        cond do
          conn.method == "GET" and String.ends_with?(conn.request_path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"transitions" => transitions_for.(cur)})

          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"fields" => %{"status" => %{"name" => cur}}})

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            id = Jason.decode!(body)["transition"]["id"]
            Agent.update(agent, fn _ -> advance.(id) end)

            conn
            |> Plug.Conn.put_status(204)
            |> Req.Test.json(%{})
        end
      end)

      # Backlog -> To Do -> In Progress (2 hops, neither reachable directly).
      assert :ok = Jira.transition(@ref, :in_progress)
      assert Agent.get(agent, & &1) == "In Progress"
    end

    test "no-ops (no POST) when the issue is already at the target status" do
      stub(fn conn ->
        assert conn.method == "GET"

        if String.ends_with?(conn.request_path, "/transitions") do
          # No live transition lands on "Done" — forces the current-status check.
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "transitions" => [
              %{"id" => "9", "name" => "Reopen", "to" => %{"name" => "In Progress"}}
            ]
          })
        else
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"fields" => %{"status" => %{"name" => "Done"}}})
        end
      end)

      assert :ok = Jira.transition(@ref, :closed)
    end

    test "returns {:error, :status_unmapped} when the event has no target status mapped" do
      Config.put_active(%{
        "host" => @host,
        "project_key" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "email" => "tester@example.com",
        "status_map" => %{
          "open" => "To Do",
          "in_progress" => "In Progress",
          "closed" => ""
        }
      })

      assert {:error, %Error{kind: :status_unmapped}} = Jira.transition(@ref, :closed)
    end

    test "returns {:error, :no_transition_path} when the target status is unreachable" do
      Config.put_active(%{
        "host" => @host,
        "project_key" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "email" => "tester@example.com",
        "status_map" => %{"closed" => "Nowhere"}
      })

      stub(fn conn ->
        assert conn.method == "GET"

        if String.ends_with?(conn.request_path, "/transitions") do
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "transitions" => [
              %{"id" => "1", "name" => "noop", "to" => %{"name" => "In Progress"}}
            ]
          })
        else
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"fields" => %{"status" => %{"name" => "In Progress"}}})
        end
      end)

      assert {:error, %Error{kind: :no_transition_path}} = Jira.transition(@ref, :closed)
    end
  end

  describe "plan_transition_path/3 (pure BFS)" do
    @graph %{
      "Backlog" => [
        %{"transition" => "To do next", "to" => "To Do"},
        %{"transition" => "Put on ice", "to" => "Backlog"}
      ],
      "To Do" => [%{"transition" => "Start work", "to" => "In Progress"}],
      "In Progress" => [%{"transition" => "Pull request created", "to" => "In Code Review"}]
    }

    test "finds the shortest multi-hop path (Backlog -> To Do -> In Progress)" do
      assert {:ok, ["To do next", "Start work"]} =
               Jira.plan_transition_path(@graph, "Backlog", "In Progress")
    end

    test "returns an empty path when already at the target" do
      assert {:ok, []} = Jira.plan_transition_path(@graph, "In Progress", "In Progress")
    end

    test "returns :no_transition_path when the target is unreachable" do
      assert {:error, %Error{kind: :no_transition_path}} =
               Jira.plan_transition_path(@graph, "Backlog", "Mars")
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

  describe "add_remote_link/3" do
    test "POSTs a remote link with the url, title, and an idempotent globalId" do
      url = "https://github.com/leo/voice-id-core/pull/42"
      title = "PR leo/voice-id-core#42 (task bd-abc)"

      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}/remotelink"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["object"]["url"] == url
        assert decoded["object"]["title"] == title
        # globalId keys off the URL so re-posting the same PR is idempotent.
        assert decoded["globalId"] == "arbiter-pr=#{url}"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 10_001})
      end)

      assert :ok = Jira.add_remote_link(@ref, url, title)
    end

    test "propagates an HTTP error" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"errorMessages" => ["Issue does not exist"]})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} =
               Jira.add_remote_link(@ref, "https://example.com/pr/1", "PR 1")
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
    test "parses the transitions response and maps to task-status atoms" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}/transitions"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "transitions" => [
            %{"id" => "11", "name" => "start", "to" => %{"name" => "To Do"}},
            %{"id" => "21", "name" => "go", "to" => %{"name" => "In Progress"}},
            %{"id" => "31", "name" => "finish", "to" => %{"name" => "Done"}},
            # Destinations without a mapping in status_map are dropped.
            %{"id" => "41", "name" => "x", "to" => %{"name" => "Some Unmapped Status"}}
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

  describe "add_comment/2" do
    test "POSTs an ADF comment body to the issue comment endpoint" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/rest/api/3/issue/#{@ref}/comment"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Markdown is ADF-encoded.
        assert decoded["body"]["type"] == "doc"
        assert decoded["body"]["version"] == 1
        assert is_list(decoded["body"]["content"])

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "10100"})
      end)

      assert :ok = Jira.add_comment(@ref, "Opened PR https://github.com/leo/x/pull/9")
    end

    test "propagates an HTTP error" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"errorMessages" => ["Issue does not exist"]})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} = Jira.add_comment(@ref, "hi")
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:jira) resolves to this adapter (no raise)" do
      assert Arbiter.Trackers.for_type(:jira) == Jira
    end
  end

  describe "list_open/1" do
    test "POSTs to /search/jql with a JSON body and returns matching issues" do
      stub(fn conn ->
        # Migrated off the removed GET /search (CHANGE-2046).
        assert conn.method == "POST"
        assert conn.request_path == "/rest/api/3/search/jql"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["jql"] =~ "currentUser()"
        assert body["jql"] =~ "resolution = Unresolved"
        assert body["maxResults"] == 100
        # Fields are explicit — /search/jql returns only id/key otherwise.
        assert "summary" in body["fields"]
        assert "status" in body["fields"]
        assert "assignee" in body["fields"]
        # First page: no page token.
        refute Map.has_key?(body, "nextPageToken")

        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "VR-42",
              "fields" => %{
                "summary" => "Open ticket",
                "assignee" => %{"accountId" => "account-123"},
                "status" => %{"statusCategory" => %{"key" => "new"}}
              }
            }
          ]
        })
      end)

      assert {:ok, [summary]} = Jira.list_open([])
      assert summary.ref == "VR-42"
      assert summary.title == "Open ticket"
      assert summary.status == :open
      assert summary.assignees == ["account-123"]
    end

    test "follows nextPageToken pagination until exhausted" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        case body["nextPageToken"] do
          nil ->
            # Page 1 hands back a token for page 2.
            Req.Test.json(conn, %{
              "issues" => [issue("VR-1")],
              "nextPageToken" => "tok-2"
            })

          "tok-2" ->
            # Page 2 is the last page (no token).
            Req.Test.json(conn, %{"issues" => [issue("VR-2")]})
        end
      end)

      assert {:ok, [first, second]} = Jira.list_open([])
      assert first.ref == "VR-1"
      assert second.ref == "VR-2"
    end

    test "accepts an explicit assignee id" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["jql"] =~ "account-456"
        Req.Test.json(conn, %{"issues" => []})
      end)

      assert {:ok, []} = Jira.list_open(assignee: "account-456")
    end

    test "returns empty list when no issues match" do
      stub(fn conn ->
        Req.Test.json(conn, %{"issues" => []})
      end)

      assert {:ok, []} = Jira.list_open([])
    end

    test "propagates an HTTP error" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"errorMessages" => ["Bad JQL"]})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 400}} = Jira.list_open([])
    end
  end

  describe "create/1" do
    test "POSTs /issue with project, issuetype, summary and ADF description; returns the key" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/rest/api/3/issue"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        fields = Jason.decode!(raw)["fields"]

        assert fields["project"] == %{"key" => @project}
        assert fields["issuetype"] == %{"name" => "Bug"}
        assert fields["summary"] == "Wire the thing"

        # description is markdown -> ADF doc.
        adf = fields["description"]
        assert adf["type"] == "doc"
        assert adf["version"] == 1
        assert is_list(adf["content"])

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "10042", "key" => "VR-999"})
      end)

      assert {:ok, "VR-999"} =
               Jira.create(%{
                 title: "Wire the thing",
                 description: "Do the **thing**.",
                 issue_type: "Bug"
               })
    end

    test "defaults issuetype to Task when none is given" do
      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["fields"]["issuetype"] == %{"name" => "Task"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"key" => "VR-1000"})
      end)

      assert {:ok, "VR-1000"} = Jira.create(%{title: "No type"})
    end

    test "requires a non-empty title" do
      assert {:error, %Error{kind: :validation_failed}} = Jira.create(%{description: "no title"})
    end

    test "maps a validation error from Jira" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"errorMessages" => ["issuetype is required"]})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 400}} =
               Jira.create(%{title: "x"})
    end
  end

  describe "extract_description/1" do
    test "flattens an ADF document to plain text" do
      issue = %{
        "fields" => %{
          "description" => %{
            "type" => "doc",
            "version" => 1,
            "content" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "text" => "First line."}]
              },
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "text" => "Second line."}]
              }
            ]
          }
        }
      }

      assert Jira.extract_description(issue) == "First line.\n\nSecond line."
    end

    test "passes a plain-text description through" do
      issue = %{"fields" => %{"description" => "just text"}}
      assert Jira.extract_description(issue) == "just text"
    end

    test "returns empty string for nil or missing description" do
      assert Jira.extract_description(%{"fields" => %{"description" => nil}}) == ""
      assert Jira.extract_description(%{"fields" => %{}}) == ""
      assert Jira.extract_description(%{}) == ""
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
