defmodule ArbiterCli.Cmd.WorkspaceTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Workspace

  test "list renders the configured workspaces" do
    stub_get("/api/workspaces", %{
      "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
    })

    {out, _err, code} = capture(fn -> Workspace.run(["list"]) end)
    assert code == 0
    assert out =~ "default"
    assert out =~ "prefix=bd"
  end

  test "show renders one workspace" do
    stub_get("/api/workspaces/ws-1", %{"id" => "ws-1", "name" => "default", "prefix" => "bd"})

    {out, _err, code} = capture(fn -> Workspace.run(["show", "ws-1"]) end)
    assert code == 0
    assert out =~ "default"
  end

  test "show requires an id" do
    {_out, err, code} = capture(fn -> Workspace.run(["show"]) end)
    assert code == 1
    assert err =~ "workspace show requires"
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Workspace.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown workspace subcommand"
  end

  describe "secret" do
    defp stub_one_workspace(secret_keys) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => secret_keys}
        ]
      })
    end

    test "secret ls lists configured key names" do
      stub_one_workspace(["tracker_token", "merge_token"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "tracker_token"
      assert out =~ "merge_token"
    end

    test "secret ls reports when none are set" do
      stub_one_workspace([])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "(no secrets)"
    end

    test "secret set patches the workspace and echoes the resulting keys" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => []}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         {%{"id" => "ws-1", "secret_keys" => ["tracker_token"]}, 200}}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "sct_rw_x", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "tracker_token"
      # The token value is never printed back.
      refute out =~ "sct_rw_x"
    end

    test "secret set requires a value" do
      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "requires <key> <value>"
    end

    test "secret rm removes an existing key" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "secret_keys" => ["tracker_token"]
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"}, {%{"id" => "ws-1", "secret_keys" => []}, 200}}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "ok"
    end

    test "secret rm rejects an unknown key" do
      stub_one_workspace(["other"])

      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "no secret named"
    end

    test "unknown secret subcommand errors" do
      {_out, err, code} = capture(fn -> Workspace.run(["secret", "frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown workspace secret subcommand"
    end
  end

  describe "create" do
    test "posts a workspace with config built from flags" do
      stub_routes([
        {{"post", "/api/workspaces"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["name"] == "acme"
           assert decoded["prefix"] == "ac"
           assert decoded["config"]["tracker"]["type"] == "github"
           assert decoded["config"]["merge"]["strategy"] == "gitlab"
           assert decoded["description"] == "Acme backend"

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "ws-9", "name" => "acme", "prefix" => "ac"})
         end}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "create",
            "acme",
            "--prefix",
            "ac",
            "--tracker-type",
            "github",
            "--merger-strategy",
            "gitlab",
            "--description",
            "Acme backend"
          ])
        end)

      assert code == 0
      assert out =~ "created workspace acme"
      assert out =~ "ws-9"
    end

    test "defaults prefix/tracker/merger when flags omitted" do
      stub_routes([
        {{"post", "/api/workspaces"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["prefix"] == "bd"
           assert decoded["config"]["tracker"]["type"] == "none"
           assert decoded["config"]["merge"]["strategy"] == "direct"
           refute Map.has_key?(decoded, "description")

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "ws-1", "name" => "plain", "prefix" => "bd"})
         end}
      ])

      {out, _err, code} = capture(fn -> Workspace.run(["create", "plain"]) end)
      assert code == 0
      assert out =~ "created workspace plain"
    end

    test "requires a name" do
      {_out, err, code} = capture(fn -> Workspace.run(["create"]) end)
      assert code == 1
      assert err =~ "requires a name"
    end

    test "rejects an invalid tracker type before calling the API" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["create", "x", "--tracker-type", "bogus"]) end)

      assert code == 1
      assert err =~ "invalid --tracker-type"
    end

    test "rejects an invalid merger strategy before calling the API" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["create", "x", "--merger-strategy", "bogus"]) end)

      assert code == 1
      assert err =~ "invalid --merger-strategy"
    end
  end

  describe "standing-order" do
    defp ws_with_orders(orders) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"standing_orders" => orders}
          }
        ]
      })
    end

    defp stub_order_patch(initial, expected, returned) do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "config" => %{"standing_orders" => initial}
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"]["standing_orders"] == expected

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "id" => "ws-1",
             "name" => "default",
             "config" => %{"standing_orders" => returned}
           })
         end}
      ])
    end

    test "ls lists the orders with 1-based indices" do
      ws_with_orders(["First order", "Second order"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "1. First order"
      assert out =~ "2. Second order"
    end

    test "ls reports when there are none" do
      ws_with_orders([])

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "(no standing orders)"
    end

    test "add appends without clobbering existing orders" do
      stub_order_patch(["Keep one"], ["Keep one", "Add two"], ["Keep one", "Add two"])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "add", "Add two", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "2 standing order(s)"
      assert out =~ "Add two"
    end

    test "rm removes by 1-based index" do
      stub_order_patch(["a", "b", "c"], ["a", "c"], ["a", "c"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "rm", "2", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "2 standing order(s)"
    end

    test "rm removes by exact text match" do
      stub_order_patch(["keep", "drop me"], ["keep"], ["keep"])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "rm", "drop me", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "1 standing order(s)"
    end

    test "rm rejects an out-of-range index" do
      ws_with_orders(["only one"])

      {_out, err, code} =
        capture(fn -> Workspace.run(["standing-order", "rm", "9", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "out of range"
    end

    test "rm errors when there are no orders" do
      ws_with_orders([])

      {_out, err, code} =
        capture(fn -> Workspace.run(["standing-order", "rm", "1", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "no standing orders"
    end
  end

  describe "standing-order --repo (canonical) and --rig (deprecated alias)" do
    defp ws_with_repo_paths(repo_paths) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"repo_paths" => repo_paths}
          }
        ]
      })
    end

    defp stub_repo_order_patch(repo_paths, expected_patch, returned_repo_paths) do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "config" => %{"repo_paths" => repo_paths}
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"]["repo_paths"] == expected_patch

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "id" => "ws-1",
             "name" => "default",
             "config" => %{"repo_paths" => returned_repo_paths}
           })
         end}
      ])
    end

    test "ls lists a repo's own orders, not the workspace-global ones" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--rig", "client"])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
    end

    test "ls reports when a registered repo has none" do
      ws_with_repo_paths(%{"client" => %{"path" => "/x/client"}})

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--rig", "client"])
        end)

      assert code == 0
      assert out =~ "(no standing orders"
    end

    test "add appends onto a map-shaped repo entry, preserving its path" do
      stub_repo_order_patch(
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["Keep one"]}},
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["Keep one", "Add two"]}},
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["Keep one", "Add two"]}}
      )

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "add",
            "Add two",
            "--workspace",
            "default",
            "--rig",
            "client"
          ])
        end)

      assert code == 0
      assert out =~ "2 standing order(s)"
    end

    test "add on a bare-string repo entry upgrades it to a map, keeping the path" do
      stub_repo_order_patch(
        %{"server" => "/x/server"},
        %{"server" => %{"path" => "/x/server", "standing_orders" => ["First order"]}},
        %{"server" => %{"path" => "/x/server", "standing_orders" => ["First order"]}}
      )

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "add",
            "First order",
            "--workspace",
            "default",
            "--rig",
            "server"
          ])
        end)

      assert code == 0
      assert out =~ "1 standing order(s)"
    end

    test "add errors when the named repo isn't registered in repo_paths" do
      ws_with_repo_paths(%{"client" => %{"path" => "/x/client"}})

      {_out, err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "add",
            "text",
            "--workspace",
            "default",
            "--rig",
            "nope"
          ])
        end)

      assert code == 1
      assert err =~ "no repo named"
    end

    test "rm removes by index scoped to the repo, leaving the global list untouched" do
      stub_repo_order_patch(
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["a", "b"]}},
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["a"]}},
        %{"client" => %{"path" => "/x/client", "standing_orders" => ["a"]}}
      )

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "rm",
            "2",
            "--workspace",
            "default",
            "--rig",
            "client"
          ])
        end)

      assert code == 0
      assert out =~ "1 standing order(s)"
    end

    test "rm errors when the repo has no orders" do
      ws_with_repo_paths(%{"client" => %{"path" => "/x/client"}})

      {_out, err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "rm",
            "1",
            "--workspace",
            "default",
            "--rig",
            "client"
          ])
        end)

      assert code == 1
      assert err =~ "no standing orders"
    end

    test "ls accepts --repo as the canonical flag, same as --rig" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--repo", "client"])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
    end

    test "--repo wins when both --repo and --rig are given" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]},
        "server" => %{"path" => "/x/server", "standing_orders" => ["Deploy to staging."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "ls",
            "--workspace",
            "default",
            "--repo",
            "client",
            "--rig",
            "server"
          ])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
      refute out =~ "Deploy to staging."
    end

    test "ls --json emits both the canonical \"repo\" key and the legacy \"rig\" key" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "ls",
            "--workspace",
            "default",
            "--repo",
            "client",
            "--json"
          ])
        end)

      assert code == 0
      {:ok, decoded} = Jason.decode(String.trim(out))
      assert decoded["repo"] == "client"
      assert decoded["rig"] == "client"
    end
  end
end
