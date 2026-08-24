defmodule ArbiterCli.Cmd.PromoteTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Promote

  test "promote success prints updated issue" do
    stub_post(
      "/api/issues/bd-001/promote",
      %{"id" => "bd-001", "title" => "X", "refined" => true},
      200
    )

    {out, _err, exit_code} = capture(fn -> Promote.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "Ready"
  end

  test "promote --json emits raw JSON" do
    stub_post(
      "/api/issues/bd-001/promote",
      %{"id" => "bd-001", "title" => "X", "refined" => true},
      200
    )

    {out, _err, exit_code} = capture(fn -> Promote.run(["bd-001", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"refined" => true}} = Jason.decode(out)
  end

  test "promote requires id" do
    {_out, err, exit_code} = capture(fn -> Promote.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "promoting an already-refined task succeeds as a no-op" do
    stub_post(
      "/api/issues/bd-001/promote",
      %{"id" => "bd-001", "title" => "X", "refined" => true},
      200
    )

    {out, _err, exit_code} = capture(fn -> Promote.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end
end
