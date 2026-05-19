defmodule GtElixirCli.Cmd.ListTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.List

  test "prints one line per issue" do
    stub_get("/api/issues", %{
      "data" => [
        %{"id" => "a", "status" => "open", "priority" => 2, "title" => "first"},
        %{"id" => "b", "status" => "closed", "priority" => 1, "title" => "second"}
      ]
    })

    {out, _err, exit_code} = capture(fn -> List.run([]) end)
    assert exit_code == 0
    assert out =~ "first"
    assert out =~ "second"
    assert out =~ "[open]"
    assert out =~ "[closed]"
  end

  test "empty list prints placeholder" do
    stub_get("/api/issues", %{"data" => []})
    {out, _err, exit_code} = capture(fn -> List.run([]) end)
    assert exit_code == 0
    assert out =~ "(no issues)"
  end

  test "--json emits {\"data\": [...]}" do
    stub_get("/api/issues", %{"data" => [%{"id" => "a", "status" => "open"}]})
    {out, _err, exit_code} = capture(fn -> List.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"data" => [_]}} = Jason.decode(String.trim(out))
  end
end
