defmodule ArbiterCli.Cmd.DemoteTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Demote

  test "demote success prints updated issue" do
    stub_post(
      "/api/issues/bd-001/demote",
      %{"id" => "bd-001", "title" => "X", "refined" => false},
      200
    )

    {out, _err, exit_code} = capture(fn -> Demote.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "Backlog"
  end

  test "demote --json emits raw JSON" do
    stub_post(
      "/api/issues/bd-001/demote",
      %{"id" => "bd-001", "title" => "X", "refined" => false},
      200
    )

    {out, _err, exit_code} = capture(fn -> Demote.run(["bd-001", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"refined" => false}} = Jason.decode(out)
  end

  test "demote requires id" do
    {_out, err, exit_code} = capture(fn -> Demote.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "demoting an already-backlog task succeeds as a no-op" do
    stub_post(
      "/api/issues/bd-001/demote",
      %{"id" => "bd-001", "title" => "X", "refined" => false},
      200
    )

    {out, _err, exit_code} = capture(fn -> Demote.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end
end
