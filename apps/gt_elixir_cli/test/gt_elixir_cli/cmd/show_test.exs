defmodule GtElixirCli.Cmd.ShowTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Show

  test "prints human-readable detail" do
    stub_get("/api/issues/gte-006", %{
      "id" => "gte-006",
      "title" => "CLI escript",
      "status" => "open",
      "priority" => 2,
      "description" => "Build it"
    })

    {out, _err, exit_code} = capture(fn -> Show.run(["gte-006"]) end)
    assert exit_code == 0
    assert out =~ "gte-006"
    assert out =~ "CLI escript"
    assert out =~ "Description:"
    assert out =~ "Build it"
  end

  test "--json emits raw JSON" do
    stub_get("/api/issues/x", %{"id" => "x", "title" => "T"})
    {out, _err, exit_code} = capture(fn -> Show.run(["x", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"id" => "x"}} = Jason.decode(String.trim(out))
  end

  test "missing id argument exits non-zero" do
    {_out, err, exit_code} = capture(fn -> Show.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "404 surfaces server message and exits with code 4" do
    stub_get(
      "/api/issues/missing",
      %{"error" => %{"type" => "not_found", "message" => "resource not found", "details" => %{}}},
      404
    )

    {_out, err, exit_code} = capture(fn -> Show.run(["missing"]) end)
    assert exit_code == 4
    assert err =~ "resource not found"
  end
end
