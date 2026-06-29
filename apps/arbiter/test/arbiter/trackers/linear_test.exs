defmodule Arbiter.Trackers.LinearTest do
  use ExUnit.Case, async: true

  alias Arbiter.Trackers.Linear
  alias Arbiter.Trackers.Linear.{Config, Error}

  # ---- parse_ref/1 ---------------------------------------------------------

  describe "parse_ref/1" do
    test "accepts a valid identifier" do
      assert {:ok, "ENG-123"} = Linear.parse_ref("ENG-123")
    end

    test "accepts multi-letter team key" do
      assert {:ok, "TEAM-1"} = Linear.parse_ref("TEAM-1")
    end

    test "accepts linear: prefix" do
      assert {:ok, "ENG-42"} = Linear.parse_ref("linear:ENG-42")
    end

    test "accepts lin- prefix" do
      assert {:ok, "ENG-42"} = Linear.parse_ref("lin-ENG-42")
    end

    test "parses Linear issue URLs" do
      url = "https://linear.app/mycompany/issue/ENG-123/some-title-slug"
      assert {:ok, "ENG-123"} = Linear.parse_ref(url)
    end

    test "rejects bare integers (no team key)" do
      assert :error = Linear.parse_ref("42")
    end

    test "rejects lowercase identifiers" do
      assert :error = Linear.parse_ref("eng-123")
    end

    test "rejects empty string" do
      assert :error = Linear.parse_ref("")
    end

    test "rejects unrelated URLs" do
      assert :error = Linear.parse_ref("https://github.com/owner/repo/issues/42")
    end

    test "rejects nil" do
      assert :error = Linear.parse_ref(nil)
    end
  end

  # ---- link_for/1 ----------------------------------------------------------

  describe "link_for/1" do
    test "builds URL with org_url_key when configured" do
      Config.put_active(%{"credentials_ref" => "test-token", "org_url_key" => "mycompany"})

      try do
        assert Linear.link_for("ENG-123") == "https://linear.app/mycompany/issue/ENG-123"
      after
        Config.clear()
      end
    end

    test "falls back to generic URL without org_url_key" do
      Config.put_active(%{"credentials_ref" => "test-token"})

      try do
        assert Linear.link_for("ENG-123") == "https://linear.app/issue/ENG-123"
      after
        Config.clear()
      end
    end

    test "falls back to generic URL when no config active" do
      assert Linear.link_for("ENG-123") == "https://linear.app/issue/ENG-123"
    end
  end

  # ---- issue_status/1 ------------------------------------------------------

  describe "issue_status/1" do
    test "maps unstarted state to :open" do
      issue = %{"state" => %{"type" => "unstarted"}}
      assert Linear.issue_status(issue) == :open
    end

    test "maps backlog state to :open" do
      issue = %{"state" => %{"type" => "backlog"}}
      assert Linear.issue_status(issue) == :open
    end

    test "maps started state to :in_progress" do
      issue = %{"state" => %{"type" => "started"}}
      assert Linear.issue_status(issue) == :in_progress
    end

    test "maps completed state to :closed" do
      issue = %{"state" => %{"type" => "completed"}}
      assert Linear.issue_status(issue) == :closed
    end

    test "maps cancelled state to :closed" do
      issue = %{"state" => %{"type" => "cancelled"}}
      assert Linear.issue_status(issue) == :closed
    end

    test "defaults to :open for unknown state type" do
      issue = %{"state" => %{"type" => "triage"}}
      assert Linear.issue_status(issue) == :open
    end

    test "defaults to :open for missing state" do
      assert Linear.issue_status(%{}) == :open
    end
  end

  # ---- extract_title/1 and extract_description/1 ---------------------------

  describe "extract_title/1" do
    test "returns title from raw issue" do
      assert Linear.extract_title(%{"title" => "My Issue"}) == "My Issue"
    end

    test "returns fallback for missing title" do
      assert Linear.extract_title(%{}) == "(no title)"
    end

    test "returns fallback for empty title" do
      assert Linear.extract_title(%{"title" => ""}) == "(no title)"
    end
  end

  describe "extract_description/1" do
    test "returns description from raw issue" do
      assert Linear.extract_description(%{"description" => "Some desc"}) == "Some desc"
    end

    test "returns empty string for missing description" do
      assert Linear.extract_description(%{}) == ""
    end
  end

  # ---- assignees/1 ---------------------------------------------------------

  describe "assignees/1" do
    test "extracts assignee IDs from nested nodes" do
      issue = %{
        "assignees" => %{
          "nodes" => [
            %{"id" => "user-1", "name" => "Alice"},
            %{"id" => "user-2", "name" => "Bob"}
          ]
        }
      }

      assert Linear.assignees(issue) == ["user-1", "user-2"]
    end

    test "returns empty list for no assignees" do
      assert Linear.assignees(%{"assignees" => %{"nodes" => []}}) == []
    end

    test "returns empty list for missing assignees key" do
      assert Linear.assignees(%{}) == []
    end
  end

  # ---- Config.resolve/0 ---------------------------------------------------

  describe "Config.resolve/0" do
    test "returns config_missing error with no active config" do
      Config.clear()
      assert {:error, %Error{kind: :config_missing}} = Config.resolve()
    end

    test "resolves a literal token" do
      Config.put_active(%{"credentials_ref" => "lin_api_testtoken"})

      try do
        assert {:ok, cfg} = Config.resolve()
        assert cfg.token == "lin_api_testtoken"
        assert cfg.team_id == nil
        assert cfg.org_url_key == nil
        assert cfg.base_url == "https://api.linear.app/graphql"
      after
        Config.clear()
      end
    end

    test "resolves team_id and org_url_key from config" do
      Config.put_active(%{
        "credentials_ref" => "token",
        "team_id" => "team-uuid-123",
        "org_url_key" => "acme"
      })

      try do
        assert {:ok, cfg} = Config.resolve()
        assert cfg.team_id == "team-uuid-123"
        assert cfg.org_url_key == "acme"
      after
        Config.clear()
      end
    end

    test "builds status_map from config" do
      Config.put_active(%{
        "credentials_ref" => "token",
        "status_map" => %{
          "open" => "Backlog",
          "in_progress" => "In Progress",
          "closed" => "Done"
        }
      })

      try do
        assert {:ok, cfg} = Config.resolve()
        assert cfg.status_map[:open] == "Backlog"
        assert cfg.status_map[:in_progress] == "In Progress"
        assert cfg.status_map[:closed] == "Done"
      after
        Config.clear()
      end
    end

    test "resolves env: credentials_ref" do
      System.put_env("LINEAR_TEST_TOKEN_XYZ", "lin_api_envtoken")

      Config.put_active(%{"credentials_ref" => "env:LINEAR_TEST_TOKEN_XYZ"})

      try do
        assert {:ok, cfg} = Config.resolve()
        assert cfg.token == "lin_api_envtoken"
      after
        Config.clear()
        System.delete_env("LINEAR_TEST_TOKEN_XYZ")
      end
    end

    test "returns config_missing for unset env: ref" do
      Config.put_active(%{"credentials_ref" => "env:LINEAR_DEFINITELY_NOT_SET_XYZ"})

      try do
        assert {:error, %Error{kind: :config_missing}} = Config.resolve()
      after
        Config.clear()
      end
    end
  end

  # ---- with_workspace/2 ----------------------------------------------------

  describe "with_workspace/2" do
    test "seeds config and restores previous state" do
      Config.clear()

      Linear.with_workspace(%{"credentials_ref" => "token-inside"}, fn ->
        assert {:ok, cfg} = Config.resolve()
        assert cfg.token == "token-inside"
      end)

      assert {:error, %Error{kind: :config_missing}} = Config.resolve()
    end

    test "restores prior config when nested" do
      Config.put_active(%{"credentials_ref" => "outer-token"})

      try do
        Linear.with_workspace(%{"credentials_ref" => "inner-token"}, fn ->
          assert {:ok, cfg} = Config.resolve()
          assert cfg.token == "inner-token"
        end)

        assert {:ok, cfg} = Config.resolve()
        assert cfg.token == "outer-token"
      after
        Config.clear()
      end
    end
  end

  # ---- HTTP stub tests (fetch, transition, list_open, create, etc.) ---------

  describe "fetch/1 (HTTP stub)" do
    setup do
      Application.put_env(:arbiter, :linear_http_stub, true)
      Config.put_active(%{"credentials_ref" => "test-token"})
      on_exit(fn ->
        Application.delete_env(:arbiter, :linear_http_stub)
        Config.clear()
      end)
    end

    test "returns the issue map on success" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issue" => %{
              "id" => "issue-uuid-1",
              "identifier" => "ENG-1",
              "title" => "Test issue",
              "description" => "A description",
              "url" => "https://linear.app/test/issue/ENG-1/test-issue",
              "state" => %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"},
              "assignees" => %{"nodes" => []},
              "team" => %{"id" => "team-1", "key" => "ENG"}
            }
          }
        })
      end)

      assert {:ok, issue} = Linear.fetch("ENG-1")
      assert issue["identifier"] == "ENG-1"
      assert issue["title"] == "Test issue"
    end

    test "returns not_found error when issue missing" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "errors" => [%{"message" => "Entity not found - Could not find referenced Issue"}]
        })
      end)

      assert {:error, %Error{kind: :graphql_error}} = Linear.fetch("ENG-999")
    end

    test "returns unauthenticated error on 401" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Authentication required"})
      end)

      assert {:error, %Error{kind: :unauthenticated}} = Linear.fetch("ENG-1")
    end
  end

  describe "current_user/0 (HTTP stub)" do
    setup do
      Application.put_env(:arbiter, :linear_http_stub, true)
      Config.put_active(%{"credentials_ref" => "test-token"})
      on_exit(fn ->
        Application.delete_env(:arbiter, :linear_http_stub)
        Config.clear()
      end)
    end

    test "returns the viewer's id" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "viewer" => %{"id" => "user-uuid-42", "name" => "Alice", "email" => "alice@example.com"}
          }
        })
      end)

      assert {:ok, "user-uuid-42"} = Linear.current_user()
    end
  end

  describe "add_comment/2 (HTTP stub)" do
    setup do
      Application.put_env(:arbiter, :linear_http_stub, true)
      Config.put_active(%{"credentials_ref" => "test-token"})
      on_exit(fn ->
        Application.delete_env(:arbiter, :linear_http_stub)
        Config.clear()
      end)
    end

    test "posts a comment and returns :ok" do
      call_count = :counters.new(1, [])

      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)

        if String.contains?(parsed["query"] || "", "issue(id:") or
             String.contains?(parsed["query"] || "", "issue(") do
          # fetch call
          :counters.add(call_count, 1, 1)

          Req.Test.json(conn, %{
            "data" => %{
              "issue" => %{
                "id" => "issue-uuid-1",
                "identifier" => "ENG-1",
                "title" => "Test",
                "description" => "",
                "url" => "https://linear.app/test/issue/ENG-1",
                "state" => %{"id" => "s1", "name" => "Todo", "type" => "unstarted"},
                "assignees" => %{"nodes" => []},
                "team" => %{"id" => "team-1", "key" => "ENG"}
              }
            }
          })
        else
          # commentCreate call
          :counters.add(call_count, 1, 1)

          Req.Test.json(conn, %{
            "data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-1"}}}
          })
        end
      end)

      assert :ok = Linear.add_comment("ENG-1", "A comment body")
    end
  end

  describe "list_open/1 (HTTP stub)" do
    setup do
      Application.put_env(:arbiter, :linear_http_stub, true)
      Config.put_active(%{"credentials_ref" => "test-token"})
      on_exit(fn ->
        Application.delete_env(:arbiter, :linear_http_stub)
        Config.clear()
      end)
    end

    test "returns normalized summaries" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => "issue-1",
                  "identifier" => "ENG-10",
                  "title" => "Fix the thing",
                  "url" => "https://linear.app/test/issue/ENG-10",
                  "state" => %{"id" => "s1", "name" => "In Progress", "type" => "started"},
                  "assignees" => %{"nodes" => [%{"id" => "user-1", "name" => "Alice"}]}
                }
              ]
            }
          }
        })
      end)

      assert {:ok, [summary]} = Linear.list_open([])
      assert summary.ref == "ENG-10"
      assert summary.title == "Fix the thing"
      assert summary.status == :in_progress
      assert summary.assignees == ["user-1"]
    end

    test "returns empty list when no issues" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        Req.Test.json(conn, %{"data" => %{"issues" => %{"nodes" => []}}})
      end)

      assert {:ok, []} = Linear.list_open([])
    end
  end

  describe "create/1 (HTTP stub)" do
    setup do
      Application.put_env(:arbiter, :linear_http_stub, true)
      Config.put_active(%{"credentials_ref" => "test-token", "team_id" => "team-uuid-1"})
      on_exit(fn ->
        Application.delete_env(:arbiter, :linear_http_stub)
        Config.clear()
      end)
    end

    test "creates an issue and returns the identifier" do
      Req.Test.stub(Arbiter.Trackers.Linear.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)

        cond do
          String.contains?(parsed["query"] || "", "TeamStates") or
              String.contains?(parsed["query"] || "", "states") ->
            Req.Test.json(conn, %{
              "data" => %{
                "team" => %{
                  "states" => %{
                    "nodes" => [
                      %{"id" => "state-todo", "name" => "Todo", "type" => "unstarted"}
                    ]
                  }
                }
              }
            })

          true ->
            Req.Test.json(conn, %{
              "data" => %{
                "issueCreate" => %{
                  "success" => true,
                  "issue" => %{"id" => "new-issue-uuid", "identifier" => "ENG-99"}
                }
              }
            })
        end
      end)

      assert {:ok, "ENG-99"} = Linear.create(%{title: "New Issue"})
    end

    test "returns validation_failed when title missing" do
      assert {:error, %Error{kind: :validation_failed}} = Linear.create(%{description: "no title"})
    end
  end

  # ---- extract_priority/1 ----------------------------------------------------

  describe "extract_priority/1" do
    test "Urgent (1) maps to P0 — 0 is the highest priority" do
      assert {:ok, 0} = Linear.extract_priority(%{"priority" => 1})
    end

    test "High (2) maps to P1" do
      assert {:ok, 1} = Linear.extract_priority(%{"priority" => 2})
    end

    test "Medium (3) maps to P2" do
      assert {:ok, 2} = Linear.extract_priority(%{"priority" => 3})
    end

    test "Low (4) maps to P3" do
      assert {:ok, 3} = Linear.extract_priority(%{"priority" => 4})
    end

    test "None (0) returns nil — not P0; Linear has no Low equivalent so 0 means unset" do
      assert nil == Linear.extract_priority(%{"priority" => 0})
    end

    test "missing priority key returns nil" do
      assert nil == Linear.extract_priority(%{})
    end
  end

  # ---- extract_difficulty/1 --------------------------------------------------

  describe "extract_difficulty/1" do
    test "returns nil when no estimate_buckets configured" do
      # Linear difficulty is opt-in; no config means nil
      Config.put_active(%{"credentials_ref" => "test-token"})

      try do
        assert nil == Linear.extract_difficulty(%{"estimate" => 5})
      after
        Config.clear()
      end
    end

    test "maps estimate points to difficulty buckets — 0 is trivial, 4 is extreme" do
      Config.put_active(%{
        "credentials_ref" => "test-token",
        "difficulty" => %{"buckets" => [[1, 0], [3, 1], [5, 2], [8, 3]]}
      })

      try do
        assert {:ok, 0} = Linear.extract_difficulty(%{"estimate" => 1})
        assert {:ok, 1} = Linear.extract_difficulty(%{"estimate" => 3})
        assert {:ok, 2} = Linear.extract_difficulty(%{"estimate" => 5})
        assert {:ok, 3} = Linear.extract_difficulty(%{"estimate" => 8})
        assert {:ok, 4} = Linear.extract_difficulty(%{"estimate" => 13})
      after
        Config.clear()
      end
    end

    test "returns nil when estimate field is absent" do
      Config.put_active(%{
        "credentials_ref" => "test-token",
        "difficulty" => %{"buckets" => [[1, 0], [3, 1], [5, 2], [8, 3]]}
      })

      try do
        assert nil == Linear.extract_difficulty(%{})
      after
        Config.clear()
      end
    end
  end
end
