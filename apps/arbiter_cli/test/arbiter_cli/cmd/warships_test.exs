defmodule ArbiterCli.Cmd.WarshipsTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Main

  describe "arb warships (deprecated alias for arb repo list)" do
    test "runs arb repo list and prints a migration note" do
      stub_get("/api/repos", %{
        "data" => [
          %{"name" => "arbiter", "path" => "/home/ryan/dev/arbiter", "source" => "config"}
        ]
      })

      {out, err, code} = capture(fn -> Main.main(["warships"]) end)
      assert code == 0
      assert out =~ "arbiter"
      assert err =~ "`arb warships` is now `arb repo list`"
    end

    test "empty list still prints the placeholder" do
      stub_get("/api/repos", %{"data" => []})
      {out, _err, code} = capture(fn -> Main.main(["warships"]) end)
      assert code == 0
      assert out =~ "(no repos registered)"
    end
  end
end
