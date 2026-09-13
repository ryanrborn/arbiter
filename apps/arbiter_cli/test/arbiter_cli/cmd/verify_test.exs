defmodule ArbiterCli.Cmd.VerifyTest do
  @moduledoc "bd-9so315 — `arb issue verify <id> --observed/--failed`."
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Verify

  test "--observed posts the observed outcome and prints the closed issue" do
    stub_post(
      "/api/issues/bd-001/verify",
      %{
        "id" => "bd-001",
        "title" => "X",
        "status" => "closed",
        "verification_outcome" => "observed"
      },
      200
    )

    {out, _err, exit_code} =
      capture(fn -> Verify.run(["bd-001", "--observed", "doctor reports 3 repos"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "--failed posts the failed outcome" do
    stub_post(
      "/api/issues/bd-001/verify",
      %{
        "id" => "bd-001",
        "title" => "X",
        "status" => "open",
        "verification_outcome" => "failed"
      },
      200
    )

    {out, _err, exit_code} =
      capture(fn -> Verify.run(["bd-001", "--failed", "still broken", "--json"]) end)

    assert exit_code == 0
    assert {:ok, %{"verification_outcome" => "failed"}} = Jason.decode(out)
  end

  test "requires an issue id" do
    {_out, err, exit_code} = capture(fn -> Verify.run(["--observed", "x"]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "requires exactly one of --observed / --failed" do
    {_out, err, exit_code} = capture(fn -> Verify.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "--observed"

    {_out, err2, exit2} =
      capture(fn -> Verify.run(["bd-001", "--observed", "a", "--failed", "b"]) end)

    assert exit2 == 1
    assert err2 =~ "not both"
  end
end
