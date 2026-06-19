defmodule ArbiterCli.WorkspaceTest do
  # async: false — the `--workspace` flow mutates the ARB_WORKSPACE env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Issue
  alias ArbiterCli.Workspace

  describe "take_flag/1" do
    test "extracts `--workspace <name>` and returns the remaining argv" do
      assert {"leotech", ["list", "--tracker"]} =
               Workspace.take_flag(["list", "--workspace", "leotech", "--tracker"])
    end

    test "supports the `--workspace=<name>` form" do
      assert {"leotech", ["list"]} = Workspace.take_flag(["list", "--workspace=leotech"])
    end

    test "supports the `-w <name>` and `-w=<name>` short forms" do
      assert {"leotech", ["list"]} = Workspace.take_flag(["list", "-w", "leotech"])
      assert {"leotech", ["list"]} = Workspace.take_flag(["list", "-w=leotech"])
    end

    test "returns {nil, argv} when no flag is present" do
      assert {nil, ["list", "--tracker"]} = Workspace.take_flag(["list", "--tracker"])
    end

    test "the last occurrence wins" do
      assert {"b", ["list"]} =
               Workspace.take_flag(["--workspace", "a", "list", "--workspace", "b"])
    end

    test "does not consume the unrelated --workspace-id flag" do
      assert {nil, ["list", "--workspace-id", "ws-1"]} =
               Workspace.take_flag(["list", "--workspace-id", "ws-1"])
    end
  end

  describe "arb issue list --workspace <name> routing" do
    setup do
      prev = System.get_env("ARB_WORKSPACE")

      on_exit(fn ->
        if prev,
          do: System.put_env("ARB_WORKSPACE", prev),
          else: System.delete_env("ARB_WORKSPACE")
      end)

      :ok
    end

    test "routes the tracker query to the workspace named by the flag, not the default" do
      System.put_env("ARB_WORKSPACE", "default")

      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-default", "name" => "default", "prefix" => "bd"},
              %{"id" => "ws-leo", "name" => "leotech", "prefix" => "vr"}
            ]
          }, 200}},
        # Only the leotech workspace's tracker endpoint is stubbed; if the flag
        # were ignored, the default workspace's endpoint would be hit instead
        # and this route would 500 (unmatched).
        {{"get", "/api/workspaces/ws-leo/tracker/issues"},
         {%{
            "supported" => true,
            "data" => [%{"ref" => "VR-1", "title" => "Upstream", "status" => "open"}]
          }, 200}}
      ])

      {out, _err, code} =
        capture(fn -> Issue.run(["list", "--tracker", "--workspace", "leotech"]) end)

      assert code == 0
      assert out =~ "VR-1"
      assert out =~ "Upstream"
    end
  end
end
