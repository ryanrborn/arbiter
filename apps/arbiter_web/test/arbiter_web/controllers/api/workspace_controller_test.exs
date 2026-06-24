defmodule ArbiterWeb.Api.WorkspaceControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/workspaces" do
    test "creates a workspace", %{conn: conn} do
      conn =
        post(conn, ~p"/api/workspaces", %{
          name: "new-ws",
          prefix: "nws",
          description: "test"
        })

      body = json_response(conn, 201)
      assert body["name"] == "new-ws"
      assert body["prefix"] == "nws"
      assert body["description"] == "test"
      assert is_binary(body["id"])
    end

    test "returns 422 on invalid prefix", %{conn: conn} do
      conn = post(conn, ~p"/api/workspaces", %{name: "x", prefix: "Bad-Prefix!"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/workspaces/:id" do
    test "returns workspace", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "showme", prefix: "shw"})

      conn = get(conn, ~p"/api/workspaces/#{ws.id}")
      body = json_response(conn, 200)
      assert body["id"] == ws.id
      assert body["name"] == "showme"
    end

    test "includes the resolved acolyte security_posture", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "secure-ws",
          prefix: "scw",
          config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
        })

      conn = get(conn, ~p"/api/workspaces/#{ws.id}")
      posture = json_response(conn, 200)["security_posture"]

      assert posture["mode"] == "strict"
      # The safe-default deny baseline is surfaced and non-empty.
      assert is_list(posture["safe_defaults"]) and posture["safe_defaults"] != []
      assert posture["sandbox"]["filesystem"] == "worktree"
      # Claude adapter enforces the policy; future adapters default to false.
      assert posture["provider"] == "claude"
      assert posture["policy_enforced"] == true
    end

    test "returns 404 for missing", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      conn = get(conn, ~p"/api/workspaces/#{bogus}")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/workspaces" do
    test "lists workspaces", %{conn: conn} do
      {:ok, _} = Ash.create(Workspace, %{name: "w1", prefix: "w1"})
      {:ok, _} = Ash.create(Workspace, %{name: "w2", prefix: "w2"})

      conn = get(conn, ~p"/api/workspaces")
      assert %{"data" => list} = json_response(conn, 200)
      assert length(list) >= 2
    end
  end

  describe "PATCH /api/workspaces/:id" do
    test "activates the GitHub tracker via config", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "to-activate", prefix: "act"})

      github_config = %{
        "tracker" => %{
          "type" => "github",
          "config" => %{
            "owner" => "ryanrborn",
            "repo" => "arbiter",
            "credentials_ref" => "env:GITHUB_TOKEN"
          }
        }
      }

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{config: github_config})

      body = json_response(conn, 200)
      assert body["id"] == ws.id
      assert body["config"]["tracker"]["type"] == "github"
      assert body["config"]["tracker"]["config"]["owner"] == "ryanrborn"
    end

    test "updates scalar fields", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "rename-me", prefix: "rnm"})

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{name: "renamed", description: "now set"})

      body = json_response(conn, 200)
      assert body["name"] == "renamed"
      assert body["description"] == "now set"
    end

    test "returns 422 on an invalid tracker type", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "bad-cfg", prefix: "bad"})

      conn =
        patch(conn, ~p"/api/workspaces/#{ws.id}", %{
          config: %{"tracker" => %{"type" => "bitbucket"}}
        })

      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 404 for a missing workspace", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      conn = patch(conn, ~p"/api/workspaces/#{bogus}", %{name: "nope"})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end

    test "PUT is also accepted", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "put-me", prefix: "put"})

      conn = put(conn, ~p"/api/workspaces/#{ws.id}", %{description: "via put"})
      assert json_response(conn, 200)["description"] == "via put"
    end
  end

  describe "secrets (write-only, encrypted)" do
    test "POST accepts secrets and never returns their values", %{conn: conn} do
      conn =
        post(conn, ~p"/api/workspaces", %{
          name: "sec-api-create",
          prefix: "sac",
          secrets: %{"tracker_token" => "sct_rw_secret"}
        })

      body = json_response(conn, 201)
      # The plaintext is nowhere in the serialised response...
      refute Jason.encode!(body) =~ "sct_rw_secret"
      refute Map.has_key?(body, "secrets")
      refute Map.has_key?(body, "encrypted_secrets")
      # ...but the key name is surfaced for `arb workspace secret ls`.
      assert body["secret_keys"] == ["tracker_token"]
    end

    test "GET never returns secret values, only key names", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "sec-api-get",
          secrets: %{"b_token" => "vvv", "a_token" => "www"}
        })

      conn = get(conn, ~p"/api/workspaces/#{ws.id}")
      body = json_response(conn, 200)

      refute Jason.encode!(body) =~ "vvv"
      refute Jason.encode!(body) =~ "www"
      # Sorted key names only.
      assert body["secret_keys"] == ["a_token", "b_token"]
    end

    test "PATCH merge-patches secrets (set, then remove via null)", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "sec-api-patch", secrets: %{"keep" => "1"}})

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{secrets: %{"added" => "2"}})
      body = json_response(conn, 200)
      assert body["secret_keys"] == ["added", "keep"]

      conn =
        patch(
          build_conn() |> put_req_header("accept", "application/json"),
          ~p"/api/workspaces/#{ws.id}",
          %{secrets: %{"keep" => nil}}
        )

      body = json_response(conn, 200)
      assert body["secret_keys"] == ["added"]
    end

    test "the secret: ref resolves end-to-end with no env var", %{conn: conn} do
      conn =
        post(conn, ~p"/api/workspaces", %{
          name: "sec-api-e2e",
          prefix: "e2e",
          secrets: %{"tracker_token" => "sct_e2e"},
          config: %{
            "tracker" => %{
              "type" => "shortcut",
              "config" => %{"credentials_ref" => "secret:tracker_token"}
            }
          }
        })

      id = json_response(conn, 201)["id"]

      {:ok, ws} = Ash.get(Workspace, id)
      Arbiter.Trackers.Shortcut.Config.put_active(ws)
      assert {:ok, %{token: "sct_e2e"}} = Arbiter.Trackers.Shortcut.Config.resolve()
      Arbiter.Trackers.Shortcut.Config.clear()
    end
  end

  describe "PATCH /api/workspaces/:id/config" do
    setup do
      initial = %{
        "tracker" => %{"type" => "github", "config" => %{"owner" => "leo"}},
        "rig_paths" => %{"arbiter" => "/srv/arbiter"},
        "merge" => %{"strategy" => "github", "config" => %{"owner" => "leo", "repo" => "arb"}}
      }

      {:ok, ws} = Ash.create(Workspace, %{name: "patch-cfg", prefix: "pcf", config: initial})
      {:ok, ws: ws}
    end

    test "deep-merges a partial patch — sibling keys untouched", %{conn: conn, ws: ws} do
      conn =
        patch(conn, ~p"/api/workspaces/#{ws.id}/config", %{
          "patch" => %{"merge" => %{"auto_merge" => true}}
        })

      body = json_response(conn, 200)
      assert body["config"]["merge"]["auto_merge"] == true
      # The original footgun: replace semantics would have wiped these.
      assert body["config"]["merge"]["strategy"] == "github"
      assert body["config"]["merge"]["config"]["owner"] == "leo"
      assert body["config"]["tracker"]["type"] == "github"
      assert body["config"]["rig_paths"]["arbiter"] == "/srv/arbiter"
    end

    test "unset_paths removes a dotted leaf", %{conn: conn, ws: ws} do
      conn =
        patch(conn, ~p"/api/workspaces/#{ws.id}/config", %{
          "unset_paths" => ["tracker.config.owner"]
        })

      body = json_response(conn, 200)
      refute Map.has_key?(body["config"]["tracker"]["config"], "owner")
      assert body["config"]["tracker"]["type"] == "github"
    end

    test "empty body is a no-op (no fields changed)", %{conn: conn, ws: ws} do
      conn = patch(conn, ~p"/api/workspaces/#{ws.id}/config", %{})
      body = json_response(conn, 200)
      assert body["config"]["merge"]["strategy"] == "github"
    end

    test "validation runs on the merged result", %{conn: conn, ws: ws} do
      conn =
        patch(conn, ~p"/api/workspaces/#{ws.id}/config", %{
          "patch" => %{"tracker" => %{"type" => "asana"}}
        })

      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 404 for a missing workspace", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      conn = patch(conn, ~p"/api/workspaces/#{bogus}/config", %{"patch" => %{}})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
