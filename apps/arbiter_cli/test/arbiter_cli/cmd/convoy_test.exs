defmodule ArbiterCli.Cmd.ConvoyTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Convoy

  @convoy %{
    "id" => "bd-cv-abc123",
    "title" => "Onboarding batch",
    "status" => "open",
    "lifecycle" => "owned",
    "member_ids" => ["bd-001", "bd-002"],
    "total_issues" => 2,
    "closed_issues" => 1
  }

  describe "create" do
    test "posts to /api/convoys with the resolved workspace and prints the convoy" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"name" => "default", "id" => "ws-1", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/convoys"}, {@convoy, 201}}
      ])

      {out, _err, code} =
        capture(fn -> Convoy.run(["create", "Onboarding batch", "--json"]) end)

      assert code == 0
      assert out =~ "bd-cv-abc123"
    end

    test "requires a title" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"name" => "default", "id" => "ws-1", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, code} = capture(fn -> Convoy.run(["create"]) end)
      assert code == 1
      assert err =~ "requires a title"
    end
  end

  describe "add" do
    test "posts a member and prints the updated convoy" do
      stub_post("/api/convoys/bd-cv-abc123/members", @convoy, 200)

      {out, _err, code} =
        capture(fn -> Convoy.run(["add", "bd-cv-abc123", "bd-002", "--json"]) end)

      assert code == 0
      assert out =~ "bd-002"
    end

    test "requires a convoy id and at least one issue id" do
      {_out, err, code} = capture(fn -> Convoy.run(["add", "bd-cv-abc123"]) end)
      assert code == 1
      assert err =~ "convoy add requires"
    end
  end

  describe "rm" do
    test "deletes a member and prints the updated convoy" do
      stub_delete("/api/convoys/bd-cv-abc123/members/bd-002", @convoy, 200)

      {out, _err, code} =
        capture(fn -> Convoy.run(["rm", "bd-cv-abc123", "bd-002", "--json"]) end)

      assert code == 0
      assert out =~ "bd-cv-abc123"
    end

    test "requires both ids" do
      {_out, err, code} = capture(fn -> Convoy.run(["rm", "bd-cv-abc123"]) end)
      assert code == 1
      assert err =~ "convoy rm requires"
    end
  end

  describe "show" do
    test "gets and prints the convoy (json)" do
      stub_get("/api/convoys/bd-cv-abc123", @convoy, 200)

      {out, _err, code} =
        capture(fn -> Convoy.run(["show", "bd-cv-abc123", "--json"]) end)

      assert code == 0
      assert out =~ "bd-cv-abc123"
    end

    test "text output is vernacular-aware (prints 'Vanguard', not 'convoy')" do
      stub_routes([
        {{"get", "/api/convoys/bd-cv-abc123"}, {@convoy, 200}},
        {{"get", "/api/settings"},
         {%{"data" => %{"vernacular" => %{"batch" => "vanguard"}}}, 200}}
      ])

      {out, _err, code} = capture(fn -> Convoy.run(["show", "bd-cv-abc123"]) end)

      assert code == 0
      assert out =~ "Vanguard:"
      refute out =~ "convoy"
      assert out =~ "1/2 closed"
      assert out =~ "bd-001"
      assert out =~ "bd-002"
    end
  end

  describe "close" do
    test "posts to the close endpoint with a reason" do
      stub_post("/api/convoys/bd-cv-abc123/close", Map.put(@convoy, "status", "closed"), 200)

      {out, _err, code} =
        capture(fn -> Convoy.run(["close", "bd-cv-abc123", "--reason", "shipped", "--json"]) end)

      assert code == 0
      assert out =~ "closed"
    end
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Convoy.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown convoy subcommand"
  end

  test "no subcommand errors" do
    {_out, err, code} = capture(fn -> Convoy.run([]) end)
    assert code == 1
    assert err =~ "requires a subcommand"
  end
end
