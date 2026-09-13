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

  # bd-7mbrlg
  test "refuses a bug/feature/chore with no acceptance criteria and no --waive" do
    stub_routes([
      {{"post", "/api/issues/bd-001/promote"},
       fn conn ->
         conn
         |> Plug.Conn.put_status(422)
         |> Req.Test.json(%{
           "error" => %{
             "message" =>
               "Cannot promote a feature to Ready with no acceptance criteria. " <>
                 "Add `acceptance` to the task, or pass `acceptance_waived: \"<reason>\"` " <>
                 "to promote anyway."
           }
         })
       end}
    ])

    {_out, err, exit_code} = capture(fn -> Promote.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "acceptance criteria"
  end

  test "--waive REASON sends acceptance_waived and promotes" do
    stub_routes([
      {{"post", "/api/issues/bd-001/promote"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"acceptance_waived" => "spike, no user-facing change"}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "bd-001",
           "title" => "X",
           "refined" => true,
           "acceptance_waived" => "spike, no user-facing change"
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Promote.run(["bd-001", "--waive", "spike, no user-facing change"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
  end
end
