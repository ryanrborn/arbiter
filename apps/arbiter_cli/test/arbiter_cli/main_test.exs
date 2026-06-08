defmodule ArbiterCli.MainTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Main

  @issues %{"data" => [%{"id" => "bd-1", "title" => "T", "status" => "open"}]}
  @empty_settings %{"data" => %{"vernacular" => %{}}}

  describe "arb <resource> <verb>" do
    test "issue list dispatches to the issue resource" do
      stub_get("/api/issues", @issues)
      {out, _err, code} = capture(fn -> Main.main(["issue", "list"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end
  end

  describe "vernacular aliases" do
    test "the Sith label resolves to the canonical resource" do
      stub_routes([
        {{"get", "/api/settings"}, {@empty_settings, 200}},
        {{"get", "/api/polecats"}, {%{"data" => []}, 200}}
      ])

      {_out, _err, code} = capture(fn -> Main.main(["polecat", "list"]) end)
      assert code == 0
    end
  end

  describe "legacy flat commands" do
    test "arb list runs arb issue list and prints a migration note" do
      stub_routes([
        {{"get", "/api/settings"}, {@empty_settings, 200}},
        {{"get", "/api/issues"}, {@issues, 200}}
      ])

      {out, err, code} = capture(fn -> Main.main(["list"]) end)
      assert code == 0
      assert out =~ "bd-1"
      assert err =~ "`arb list` is now `arb issue list`"
    end

    test "arb update with no id redirects to server deploy" do
      stub_get("/api/settings", @empty_settings)
      # We only assert the redirect note; deploy will fail fast without a root,
      # which is fine — the routing is what we're checking.
      {_out, err, _code} = capture(fn -> Main.main(["update"]) end)
      assert err =~ "`arb update` is now `arb server deploy`"
    end

    test "arb warships redirects to repo list" do
      stub_routes([
        {{"get", "/api/settings"}, {@empty_settings, 200}},
        {{"get", "/api/rigs"}, {%{"data" => []}, 200}}
      ])

      {_out, err, code} = capture(fn -> Main.main(["warships"]) end)
      assert code == 0
      assert err =~ "`arb warships` is now `arb repo list`"
    end
  end

  describe "unknown command" do
    test "prints suggestions and halts 2" do
      stub_get("/api/settings", @empty_settings)
      {_out, err, code} = capture(fn -> Main.main(["isue"]) end)
      assert code == 2
      assert err =~ "unknown command: isue"
    end
  end
end
