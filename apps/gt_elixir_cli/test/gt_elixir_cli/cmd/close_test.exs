defmodule GtElixirCli.Cmd.CloseTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Close

  test "close success prints updated issue" do
    stub_post(
      "/api/issues/bd-001/close",
      %{"id" => "bd-001", "title" => "X", "status" => "closed"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "closed"
  end

  test "close with --reason" do
    stub_post(
      "/api/issues/bd-001/close",
      %{"id" => "bd-001", "title" => "X", "status" => "closed"},
      200
    )

    {out, _err, exit_code} =
      capture(fn -> Close.run(["bd-001", "--reason", "no longer needed"]) end)

    assert exit_code == 0
    assert out =~ "closed"
  end

  test "close requires id" do
    {_out, err, exit_code} = capture(fn -> Close.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end
end
