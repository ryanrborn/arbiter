defmodule ArbiterCli.Cmd.WarshipsTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Warships

  test "prints one row per repo" do
    stub_get("/api/repos", %{
      "data" => [
        %{"name" => "arbiter", "path" => "/home/ryan/dev/arbiter", "source" => "config"},
        %{"name" => "tonic", "path" => "/home/ryan/dev/tonic", "source" => "config"}
      ]
    })

    {out, _err, exit_code} = capture(fn -> Warships.run([]) end)
    assert exit_code == 0
    assert out =~ "arbiter"
    assert out =~ "/home/ryan/dev/arbiter"
    assert out =~ "tonic"
  end

  test "empty list prints placeholder" do
    stub_get("/api/repos", %{"data" => []})
    {out, _err, exit_code} = capture(fn -> Warships.run([]) end)
    assert exit_code == 0
    assert out =~ "(no warships registered)"
  end

  test "--json emits {\"data\": [...]}" do
    stub_get("/api/repos", %{
      "data" => [%{"name" => "arbiter", "path" => "/home/ryan/dev/arbiter", "source" => "config"}]
    })

    {out, _err, exit_code} = capture(fn -> Warships.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"data" => [_]}} = Jason.decode(String.trim(out))
  end
end
