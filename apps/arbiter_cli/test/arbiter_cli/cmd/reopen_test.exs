defmodule ArbiterCli.Cmd.ReopenTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Reopen

  test "reopen success prints updated issue" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{"id" => "bd-001", "title" => "X", "status" => "open"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Reopen.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "open"
  end

  test "reopen --json emits raw JSON" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{"id" => "bd-001", "title" => "X", "status" => "open"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Reopen.run(["bd-001", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"status" => "open"}} = Jason.decode(out)
  end

  test "reopen requires id" do
    {_out, err, exit_code} = capture(fn -> Reopen.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "reopen of a non-closed bead surfaces the friendly FSM reason" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{
        "error" => %{
          "type" => "validation_error",
          "message" => "validation failed",
          "details" => %{
            "errors" => [
              %{
                "field" => "status",
                "message" => "Cannot reopen issue with status open (must be :closed)"
              }
            ]
          }
        }
      },
      422
    )

    {_out, err, exit_code} = capture(fn -> Reopen.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "bd-001 could not be reopened"
    assert err =~ "must be :closed"
    refute err =~ "validation failed"
  end
end
