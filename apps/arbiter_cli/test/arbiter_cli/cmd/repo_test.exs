defmodule ArbiterCli.Cmd.RepoTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Repo

  @rigs %{
    "data" => [
      %{
        "name" => "arbiter",
        "source" => "default",
        "path" => "/dev/arbiter",
        "workers" => 1,
        "worktrees" => 2
      },
      %{
        "name" => "other",
        "source" => "(app)",
        "path" => "/dev/other",
        "workers" => 0,
        "worktrees" => 0
      }
    ]
  }

  test "list delegates to the repos endpoint" do
    stub_get("/api/repos", @rigs)
    {out, _err, code} = capture(fn -> Repo.run(["list", "--json"]) end)
    assert code == 0
    assert out =~ "arbiter"
  end

  test "show finds a repo by name" do
    stub_get("/api/repos", @rigs)
    {out, _err, code} = capture(fn -> Repo.run(["show", "arbiter", "--json"]) end)
    assert code == 0
    assert out =~ "arbiter"
    assert out =~ "/dev/arbiter"
  end

  test "show renders detail in text mode" do
    stub_get("/api/repos", @rigs)
    {out, _err, code} = capture(fn -> Repo.run(["show", "arbiter"]) end)
    assert code == 0
    assert out =~ "arbiter"
    assert out =~ "Worktrees: 2"
  end

  test "show errors when the repo is unknown" do
    stub_get("/api/repos", @rigs)
    {_out, err, code} = capture(fn -> Repo.run(["show", "ghost"]) end)
    assert code == 1
    assert err =~ "no repo named"
  end

  test "show requires a name" do
    {_out, err, code} = capture(fn -> Repo.run(["show"]) end)
    assert code == 1
    assert err =~ "requires a repo name"
  end
end
