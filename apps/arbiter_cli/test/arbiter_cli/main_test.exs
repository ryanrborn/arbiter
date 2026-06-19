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
