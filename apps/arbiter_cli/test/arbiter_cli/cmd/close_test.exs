defmodule ArbiterCli.Cmd.CloseTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Close

  @closed_issue %{"id" => "bd-001", "title" => "X", "status" => "closed"}

  defp issue_fixture(tracker_type \\ "none", tracker_ref \\ nil) do
    %{
      "id" => "bd-001",
      "title" => "X",
      "status" => "open",
      "tracker_type" => tracker_type,
      "tracker_ref" => tracker_ref
    }
  end

  test "close success prints updated issue" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {issue_fixture(), 200}},
      {{"post", "/api/issues/bd-001/close"}, {@closed_issue, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "closed"
  end

  test "close with --reason" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {issue_fixture(), 200}},
      {{"post", "/api/issues/bd-001/close"}, {@closed_issue, 200}}
    ])

    {out, _err, exit_code} =
      capture(fn -> Close.run(["bd-001", "--reason", "no longer needed"]) end)

    assert exit_code == 0
    assert out =~ "closed"
  end

  test "auto-sets close_upstream when directive has a tracker_ref" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {issue_fixture("github", "123"), 200}},
      {{"post", "/api/issues/bd-001/close"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         parsed = Jason.decode!(body)
         assert parsed["close_upstream"] == true
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@closed_issue)
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
  end

  test "does not set close_upstream when tracker_type is none" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {issue_fixture("none", nil), 200}},
      {{"post", "/api/issues/bd-001/close"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         parsed = Jason.decode!(body)
         refute Map.has_key?(parsed, "close_upstream")
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@closed_issue)
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
  end

  test "does not set close_upstream when tracker_ref is absent" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {issue_fixture("github", nil), 200}},
      {{"post", "/api/issues/bd-001/close"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         parsed = Jason.decode!(body)
         refute Map.has_key?(parsed, "close_upstream")
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@closed_issue)
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
  end

  test "proceeds with close even when pre-fetch fails" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {%{"error" => %{"message" => "not found"}}, 404}},
      {{"post", "/api/issues/bd-001/close"}, {@closed_issue, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "closed"
  end

  test "close requires id" do
    {_out, err, exit_code} = capture(fn -> Close.run([]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end
end
