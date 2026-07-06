defmodule ArbiterCli.Cmd.SkillTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Skill

  test "skill list renders name + size + description" do
    stub_get("/api/skills", %{
      "data" => [
        %{"name" => "tdd", "body" => "abc", "metadata" => %{"description" => "test first"}},
        %{"name" => "plain", "body" => "x", "metadata" => %{}}
      ]
    })

    {out, _err, exit_code} = capture(fn -> Skill.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "tdd  (3 bytes)  — test first"
    assert out =~ "plain  (1 bytes)"
  end

  test "skill create with --body posts and reports" do
    stub_post("/api/skills", %{"id" => "s1", "name" => "tdd", "body" => "write test first"}, 201)

    {out, _err, exit_code} =
      capture(fn -> Skill.run(["create", "tdd", "--body", "write test first"]) end)

    assert exit_code == 0
    assert out =~ "created skill tdd"
  end

  test "skill create surfaces a bundled-collision warning on stderr" do
    stub_post(
      "/api/skills",
      %{
        "id" => "s2",
        "name" => "code-review",
        "body" => "x",
        "warning" => "collides with a bundled skill of the same name"
      },
      201
    )

    {out, err, exit_code} =
      capture(fn -> Skill.run(["create", "code-review", "--body", "x"]) end)

    assert exit_code == 0
    assert out =~ "created skill code-review"
    assert err =~ "collides with a bundled skill"
  end

  test "skill create without a body errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run(["create", "tdd"]) end)
    assert exit_code == 1
    assert err =~ "requires a body"
  end

  test "skill update patches the named skill" do
    stub_patch("/api/skills/tdd", %{"id" => "s1", "name" => "tdd", "body" => "v2"}, 200)

    {out, _err, exit_code} =
      capture(fn -> Skill.run(["update", "tdd", "--body", "v2"]) end)

    assert exit_code == 0
    assert out =~ "updated skill tdd"
  end

  test "skill update with nothing to change errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run(["update", "tdd"]) end)
    assert exit_code == 1
    assert err =~ "nothing to change"
  end

  test "skill delete --force hits DELETE" do
    stub_delete("/api/skills/tdd", %{"name" => "tdd"}, 200)

    {out, _err, exit_code} = capture(fn -> Skill.run(["delete", "tdd", "--force"]) end)
    assert exit_code == 0
    assert out =~ "deleted skill tdd"
  end

  test "skill with no subcommand errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run([]) end)
    assert exit_code == 1
    assert err =~ "subcommand"
  end
end
