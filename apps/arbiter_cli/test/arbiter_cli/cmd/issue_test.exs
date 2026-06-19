defmodule ArbiterCli.Cmd.IssueTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Issue

  describe "verb routing" do
    test "list routes to the issue list endpoint" do
      stub_get("/api/issues", %{"data" => [%{"id" => "bd-1", "title" => "T", "status" => "open"}]})

      {out, _err, code} = capture(fn -> Issue.run(["list"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end

    test "show routes to the issue show endpoint" do
      stub_get("/api/issues/bd-1", %{"id" => "bd-1", "title" => "T"})

      {out, _err, code} = capture(fn -> Issue.run(["show", "bd-1"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end

    test "update routes to issue-edit mode (requires an id)" do
      stub_patch("/api/issues/bd-1", %{"id" => "bd-1", "title" => "T", "priority" => 2})

      {out, _err, code} =
        capture(fn -> Issue.run(["update", "bd-1", "--priority", "2", "--json"]) end)

      assert code == 0
      assert out =~ "bd-1"
    end

    test "dispatch routes to the dispatch endpoint" do
      stub_post("/api/polecats/dispatch", %{
        "bead" => %{"id" => "bd-1"},
        "polecat" => %{},
        "machine" => %{}
      })

      {out, _err, code} = capture(fn -> Issue.run(["dispatch", "bd-1", "--json"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end

    test "no subcommand errors with a usage hint" do
      {_out, err, code} = capture(fn -> Issue.run([]) end)
      assert code == 1
      assert err =~ "issue requires a subcommand"
    end

    test "unknown subcommand errors" do
      {_out, err, code} = capture(fn -> Issue.run(["frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown issue subcommand"
    end
  end
end
