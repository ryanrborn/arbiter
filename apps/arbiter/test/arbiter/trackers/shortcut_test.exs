defmodule Arbiter.Trackers.ShortcutTest do
  use ExUnit.Case, async: false

  alias Arbiter.Trackers.Shortcut
  alias Arbiter.Trackers.Shortcut.{Config, Error}

  @ref "1234"
  @env_var "GTE_SHORTCUT_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-shortcut-token")

    Config.put_active(%{
      "credentials_ref" => "env:#{@env_var}",
      "status_map" => %{
        "open" => "Unstarted",
        "in_progress" => "In Progress",
        "closed" => "Done"
      }
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fun)

  # A canonical two-workflow /workflows payload for transition tests.
  defp workflows_payload do
    [
      %{
        "id" => 100,
        "name" => "Engineering",
        "states" => [
          %{"id" => 500, "name" => "Unstarted", "type" => "unstarted"},
          %{"id" => 501, "name" => "In Progress", "type" => "started"},
          %{"id" => 502, "name" => "Done", "type" => "done"}
        ]
      },
      %{
        "id" => 200,
        "name" => "Design",
        "states" => [
          %{"id" => 600, "name" => "Unstarted", "type" => "unstarted"},
          %{"id" => 601, "name" => "Some Unmapped State", "type" => "started"}
        ]
      }
    ]
  end

  describe "fetch/1" do
    test "200: returns the parsed story map" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/stories/#{@ref}"
        assert ["test-shortcut-token"] = Plug.Conn.get_req_header(conn, "shortcut-token")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"id" => 1234, "name" => "Fix the thing", "workflow_state_id" => 501})
      end)

      assert {:ok, %{"id" => 1234, "name" => "Fix the thing"}} = Shortcut.fetch(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Resource not found."})
      end)

      assert {:error, %Error{kind: :not_found, status: 404, message: "Resource not found."}} =
               Shortcut.fetch(@ref)
    end

    test "401: returns {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Unauthorized"})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} = Shortcut.fetch(@ref)
    end

    test "503: returns {:error, %Error{kind: :server_error}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "down"})
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} = Shortcut.fetch(@ref)
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Shortcut.fetch(@ref)
    end
  end

  describe "transition/2" do
    test "looks up workflows, resolves the state id, PUTs workflow_state_id" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/workflows"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(workflows_payload())

          {"PUT", "/api/v3/stories/" <> _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body) == %{"workflow_state_id" => 502}

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"id" => 1234})
        end
      end)

      assert :ok = Shortcut.transition(@ref, :closed)
    end

    test "narrows state lookup to the configured workflow_id" do
      Config.put_active(%{
        "credentials_ref" => "env:#{@env_var}",
        "workflow_id" => 200,
        "status_map" => %{
          "open" => "Unstarted",
          "in_progress" => "In Progress",
          "closed" => "Done"
        }
      })

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/workflows"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(workflows_payload())

          {"PUT", "/api/v3/stories/" <> _} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            # Workflow 200's "Unstarted" is state 600, not 500.
            assert Jason.decode!(body) == %{"workflow_state_id" => 600}

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"id" => 1234})
        end
      end)

      assert :ok = Shortcut.transition(@ref, :open)
    end

    test "returns {:error, :transition_not_found} when the bead status has no mapping" do
      Config.put_active(%{
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "open" => "Unstarted",
          "in_progress" => "In Progress",
          "closed" => ""
        }
      })

      assert {:error, %Error{kind: :transition_not_found}} = Shortcut.transition(@ref, :closed)
    end

    test "returns {:error, :transition_not_found} when the mapped state is absent" do
      Config.put_active(%{
        "credentials_ref" => "env:#{@env_var}",
        "status_map" => %{
          "open" => "Unstarted",
          "in_progress" => "In Progress",
          "closed" => "Shipped To Production"
        }
      })

      stub(fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(workflows_payload())
      end)

      assert {:error, %Error{kind: :transition_not_found, message: msg}} =
               Shortcut.transition(@ref, :closed)

      assert msg =~ "Shipped To Production"
    end
  end

  describe "update_fields/2" do
    test "translates title -> name and description, PUTs the story" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/v3/stories/#{@ref}"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["name"] == "New title"
        assert decoded["description"] == "New body"
        refute Map.has_key?(decoded, "title")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"id" => 1234})
      end)

      assert :ok = Shortcut.update_fields(@ref, %{title: "New title", description: "New body"})
    end

    test "drops unknown fields" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded == %{"name" => "Only this"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"id" => 1234})
      end)

      assert :ok = Shortcut.update_fields(@ref, %{title: "Only this", bogus_field: "ignored"})
    end

    test "422: returns validation_failed" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Unprocessable"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Shortcut.update_fields(@ref, %{title: "x"})
    end
  end

  describe "add_remote_link/3" do
    test "POSTs an external link with the url and description" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/stories/#{@ref}/external_links"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["url"] == "https://github.com/example/pr/42"
        assert decoded["description"] == "PR 42 (bead bd-12345)"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "link-1", "url" => "https://github.com/example/pr/42"})
      end)

      assert :ok =
               Shortcut.add_remote_link(@ref, "https://github.com/example/pr/42", "PR 42 (bead bd-12345)")
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Story not found."})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} =
               Shortcut.add_remote_link(@ref, "https://github.com/example/pr/42", "PR 42")
    end

    test "401: returns {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Unauthorized"})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} =
               Shortcut.add_remote_link(@ref, "https://github.com/example/pr/42", "PR 42")
    end

    test "missing config returns {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} =
               Shortcut.add_remote_link(@ref, "https://github.com/example/pr/42", "PR 42")
    end
  end

  describe "link_for/1" do
    test "builds the app.shortcut.com story URL" do
      assert Shortcut.link_for(@ref) == "https://app.shortcut.com/story/#{@ref}"
    end
  end

  describe "parse_ref/1" do
    test "accepts the \"sc-\" prefix" do
      assert Shortcut.parse_ref("sc-1234") == {:ok, "1234"}
    end

    test "accepts the \"shortcut:\" prefix" do
      assert Shortcut.parse_ref("shortcut:1234") == {:ok, "1234"}
    end

    test "accepts a bare integer string" do
      assert Shortcut.parse_ref("1234") == {:ok, "1234"}
    end

    test "extracts the id from a full app.shortcut.com URL" do
      url = "https://app.shortcut.com/emricare/story/1234/fix-the-thing"
      assert Shortcut.parse_ref(url) == {:ok, "1234"}
    end

    test "returns :error for unrecognised strings" do
      assert Shortcut.parse_ref("not a ref") == :error
      assert Shortcut.parse_ref("") == :error
      assert Shortcut.parse_ref("sc-abc") == :error
    end

    test "returns :error for non-string input" do
      assert Shortcut.parse_ref(nil) == :error
      assert Shortcut.parse_ref(42) == :error
    end
  end

  describe "list_transitions/1" do
    test "reverse-maps workflow state names to bead-status atoms" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/workflows"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(workflows_payload())
      end)

      assert {:ok, atoms} = Shortcut.list_transitions(@ref)
      assert :open in atoms
      assert :in_progress in atoms
      assert :closed in atoms
      # "Some Unmapped State" has no status_map entry and is dropped.
      assert length(atoms) == 3
    end

    test "filters to the configured workflow_id" do
      Config.put_active(%{
        "credentials_ref" => "env:#{@env_var}",
        "workflow_id" => 200,
        "status_map" => %{
          "open" => "Unstarted",
          "in_progress" => "In Progress",
          "closed" => "Done"
        }
      })

      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(workflows_payload())
      end)

      assert {:ok, atoms} = Shortcut.list_transitions(@ref)
      # Workflow 200 only has "Unstarted" (open) mapped; the rest are unmapped.
      assert atoms == [:open]
    end
  end

  describe "Trackers integration" do
    test "Trackers.for_type(:shortcut) resolves to this adapter (no raise)" do
      assert Arbiter.Trackers.for_type(:shortcut) == Shortcut
    end
  end

  describe "list_open/1" do
    test "resolves :viewer by calling /member and then searches by owner_id" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} ->
            Req.Test.json(conn, %{"id" => "member-uuid-999"})

          {"POST", "/api/v3/stories/search"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["owner_ids"] == ["member-uuid-999"]

            Req.Test.json(conn, [
              %{
                "id" => 1234,
                "name" => "Open story",
                "app_url" => "https://app.shortcut.com/story/1234",
                "owner_ids" => ["member-uuid-999"],
                "completed" => false,
                "started" => false
              }
            ])
        end
      end)

      assert {:ok, [summary]} = Shortcut.list_open([])
      assert summary.ref == "1234"
      assert summary.title == "Open story"
      assert summary.status == :open
      assert summary.assignees == ["member-uuid-999"]
    end

    test "accepts an explicit assignee id and skips /member lookup" do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/api/v3/stories/search"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["owner_ids"] == ["explicit-member-id"]
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Shortcut.list_open(assignee: "explicit-member-id")
    end

    test "returns empty list when no stories match" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v3/member"} -> Req.Test.json(conn, %{"id" => "m123"})
          {"POST", "/api/v3/stories/search"} -> Req.Test.json(conn, [])
        end
      end)

      assert {:ok, []} = Shortcut.list_open([])
    end
  end

  describe "with_workspace/2" do
    test "scopes config to the block and restores afterwards" do
      Config.clear()

      result =
        Shortcut.with_workspace(
          %{"credentials_ref" => "env:#{@env_var}"},
          fn -> Shortcut.link_for("7") end
        )

      assert result == "https://app.shortcut.com/story/7"
      # After the block, config is cleared.
      assert {:error, %Error{kind: :config_missing}} = Shortcut.fetch("1")
    end
  end
end
