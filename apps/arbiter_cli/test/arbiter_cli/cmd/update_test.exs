defmodule ArbiterCli.Cmd.UpdateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Update

  test "updates priority via PATCH" do
    stub_patch(
      "/api/issues/bd-001",
      %{"id" => "bd-001", "title" => "X", "priority" => 0, "status" => "open"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--priority", "0"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "append-notes fetches first, then patches with combined notes" do
    stub_routes([
      {{"get", "/api/issues/bd-001"},
       {%{"id" => "bd-001", "title" => "X", "notes" => "prior"}, 200}},
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         # assert that combined notes ended up in the payload
         assert decoded["notes"] =~ "prior"
         assert decoded["notes"] =~ "addendum"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "notes" => decoded["notes"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--append-notes", "addendum"]) end)

    assert exit_code == 0
  end

  test "--qa-notes and --deployment-notes are sent as fields" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["qa_notes"] == "verify the endpoint"
         assert decoded["deployment_notes"] == "no migrations"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "qa_notes" => decoded["qa_notes"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run([
          "bd-001",
          "--qa-notes",
          "verify the endpoint",
          "--deployment-notes",
          "no migrations"
        ])
      end)

    assert exit_code == 0
  end

  test "--pr-body is sent as the pr_body field (bd-53xrmi)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["pr_body"] == "## Summary\nDid the thing."

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "pr_body" => decoded["pr_body"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--pr-body", "## Summary\nDid the thing."])
      end)

    assert exit_code == 0
  end

  test "--resume-review clears circuit_breaker_tripped and circuit_breaker_reason (bd-1atwts)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["circuit_breaker_tripped"] == false
         assert Map.has_key?(decoded, "circuit_breaker_reason")
         assert decoded["circuit_breaker_reason"] == nil

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "circuit_breaker_tripped" => false})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--resume-review"]) end)

    assert exit_code == 0
  end

  test "--repo is sent as the repo field (bd-2jum8j)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["repo"] == "emricare/tonic_device"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "repo" => decoded["repo"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--repo", "emricare/tonic_device"]) end)

    assert exit_code == 0
  end

  test "no fields supplied → error" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "at least one field flag"
  end

  test "updates difficulty via PATCH" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["difficulty"] == 3

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "difficulty" => 3})
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "3"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "--difficulty out-of-range exits non-zero before patching" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "7"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"
  end

  test "--acceptance is sent as the acceptance field" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["acceptance"] == "- Verify the new endpoint works\n- Write tests"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "acceptance" => decoded["acceptance"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--acceptance", "- Verify the new endpoint works\n- Write tests"])
      end)

    assert exit_code == 0
  end

  # bd-1ozks5: --assignee used to patch the local column, which is gone — it's
  # still accepted for interface parity but ignored, with a warning, rather
  # than rejected outright.
  test "--assignee alongside a real field patches the field, drops assignee, warns" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["priority"] == 1
         refute Map.has_key?(decoded, "assignee")

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "priority" => 1})
       end}
    ])

    {_out, err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--priority", "1", "--assignee", "alice"]) end)

    assert exit_code == 0
    assert err =~ "--assignee is deprecated"
  end

  test "an --assignee-only update is a no-op that fetches and reports the task, with a warning" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {%{"id" => "bd-001", "title" => "unchanged"}, 200}}
    ])

    {out, err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--assignee", "alice"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
    assert err =~ "--assignee is deprecated"
  end

  # bd-9so315
  describe "--verify-after-deploy" do
    test "sets the flag" do
      stub_patch("/api/issues/bd-1", %{"id" => "bd-1", "verify_after_deploy" => true})

      {out, _err, code} =
        capture(fn -> Update.edit_issue(["bd-1", "--verify-after-deploy", "--json"]) end)

      assert code == 0
      assert {:ok, %{"verify_after_deploy" => true}} = Jason.decode(out)
    end

    test "--no-verify-after-deploy clears it" do
      stub_patch("/api/issues/bd-1", %{"id" => "bd-1", "verify_after_deploy" => false})

      {out, _err, code} =
        capture(fn -> Update.edit_issue(["bd-1", "--no-verify-after-deploy", "--json"]) end)

      assert code == 0
      assert {:ok, %{"verify_after_deploy" => false}} = Jason.decode(out)
    end
  end
end
