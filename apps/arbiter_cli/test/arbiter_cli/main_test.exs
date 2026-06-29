defmodule ArbiterCli.MainTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Main

  @issues %{"data" => [%{"id" => "bd-1", "title" => "T", "status" => "open"}]}

  describe "arb <resource> <verb>" do
    test "issue list dispatches to the issue resource" do
      stub_get("/api/issues", @issues)
      {out, _err, code} = capture(fn -> Main.main(["issue", "list"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end
  end

  describe "global --workspace / -w flag" do
    setup do
      prev = System.get_env("ARB_WORKSPACE")

      on_exit(fn ->
        if prev,
          do: System.put_env("ARB_WORKSPACE", prev),
          else: System.delete_env("ARB_WORKSPACE")
      end)

      :ok
    end

    test "-w <name> before the subcommand sets ARB_WORKSPACE and dispatches correctly" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} = capture(fn -> Main.main(["-w", "myws", "issue", "list"]) end)
      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "--workspace <name> before the subcommand works" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["--workspace", "myws", "issue", "list"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "flag takes precedence over ARB_WORKSPACE env" do
      System.put_env("ARB_WORKSPACE", "default")

      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-default", "name" => "default", "prefix" => "bd"},
              %{"id" => "ws-other", "name" => "other", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["-w", "other", "issue", "list"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "other"
    end

    test "-w after the resource also works" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["issue", "list", "-w", "myws"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "unknown workspace name fails with a clear error" do
      # Use --tracker to force workspace resolution (list without --tracker fetches
      # issues first and never resolves the workspace unless needed).
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "realws", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, code} =
        capture(fn -> Main.main(["-w", "unknown-name", "issue", "list", "--tracker"]) end)

      assert code != 0
      assert err =~ "unknown-name"
    end
  end

  describe "legacy flat commands" do
    test "arb list runs arb issue list and prints a migration note" do
      stub_get("/api/issues", @issues)

      {out, err, code} = capture(fn -> Main.main(["list"]) end)
      assert code == 0
      assert out =~ "bd-1"
      assert err =~ "`arb list` is now `arb issue list`"
    end

    test "arb update with no id redirects to server deploy" do
      # We only assert the redirect note; deploy will fail fast without a root,
      # which is fine — the routing is what we're checking.
      {_out, err, _code} = capture(fn -> Main.main(["update"]) end)
      assert err =~ "`arb update` is now `arb server deploy`"
    end
  end

  describe "unknown command" do
    test "prints suggestions and halts 2" do
      {_out, err, code} = capture(fn -> Main.main(["isue"]) end)
      assert code == 2
      assert err =~ "unknown command: isue"
    end

    test "worker is now a real command — not an unknown themed alias" do
      {_out, err, code} = capture(fn -> Main.main(["worker"]) end)
      assert code == 1
      assert err =~ "worker requires a subcommand"
    end
  end
end
