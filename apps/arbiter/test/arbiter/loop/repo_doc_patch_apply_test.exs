defmodule Arbiter.Loop.RepoDocPatchApplyTest do
  @moduledoc """
  bd-1cusio: `Loop.apply_pending/2` for a `:repo_doc_patch` proposal — rung 2
  of the destination ladder (Amendment D). Exercises the real write path
  against a scratch git repo: a branch is created, `CLAUDE.md` is patched
  inside its own managed section, committed, and merged via the `:direct`
  strategy (the workspace default, so no forge credentials are needed here).
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Tasks.Workspace

  @env_key :worktree_root

  setup do
    unique = "rdp-#{:erlang.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), unique)
    File.mkdir_p!(tmp)

    repo = Path.join(tmp, "source")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(worktree_root)

    prior =
      case Application.fetch_env(:arbiter, @env_key) do
        {:ok, v} -> {:set, v}
        :error -> :unset
      end

    Application.put_env(:arbiter, @env_key, worktree_root)

    on_exit(fn ->
      case prior do
        {:set, v} -> Application.put_env(:arbiter, @env_key, v)
        :unset -> Application.delete_env(:arbiter, @env_key)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "repo-doc-patch-ws",
        prefix: "rdp",
        config: %{"repo_paths" => %{"myrepo" => repo}}
      })

    %{ws: ws, repo: repo}
  end

  defp candidate(ws, overrides) do
    Map.merge(
      %{
        kind: :repo_doc_patch,
        gist: "teach this repo: tests need FLAG=1",
        category: "repo convention",
        target: "myrepo",
        difficulty: nil,
        repo: "myrepo",
        scope: :task,
        target_metric: nil,
        baseline: nil,
        incident_refs: ["run-a"],
        task_refs: ["bd-1"],
        payload: %{"lesson" => "this repo's tests need FLAG=1 set"},
        origin: "loop.analyze",
        workspace_id: ws.id
      },
      overrides
    )
  end

  describe "apply_pending/2 — :repo_doc_patch" do
    test "writes the managed section into CLAUDE.md and merges the branch", %{ws: ws, repo: repo} do
      {:ok, row} = Loop.record(candidate(ws, %{}))

      assert {:ok, applied} = Loop.apply_pending(row.id)
      assert applied.state == :applied

      content = File.read!(Path.join(repo, "CLAUDE.md"))
      assert content =~ "this repo's tests need FLAG=1 set"
      assert content =~ "arbiter:begin"

      {log, 0} = System.cmd("git", ["-C", repo, "log", "--oneline", "-5"])
      assert log =~ "teach this repo"
    end

    test "when CLAUDE.md is a symlink to AGENTS.md, writes through symlink without replacing it", %{
      ws: ws,
      repo: repo
    } do
      agents_path = Path.join(repo, "AGENTS.md")
      claude_path = Path.join(repo, "CLAUDE.md")

      File.write!(agents_path, "# Agent conventions\n")
      File.ln_s!("AGENTS.md", claude_path)
      {_, 0} = System.cmd("git", ["-C", repo, "config", "core.symlinks", "true"])
      {_, 0} = System.cmd("git", ["-C", repo, "add", "AGENTS.md", "CLAUDE.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add AGENTS.md and CLAUDE.md symlink"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      {:ok, row} = Loop.record(candidate(ws, %{}))

      assert {:ok, applied} = Loop.apply_pending(row.id)
      assert applied.state == :applied

      assert File.read_link!(claude_path) == "AGENTS.md"

      agents_content = File.read!(agents_path)
      assert agents_content =~ "this repo's tests need FLAG=1 set"
      assert agents_content =~ "arbiter:begin"
    end

    test "a repo not registered in the workspace's repo_paths fails cleanly", %{ws: ws} do
      {:ok, row} = Loop.record(candidate(ws, %{repo: "unknown-repo", target: "unknown-repo"}))

      assert {:error, {:unmapped, reason}} = Loop.apply_pending(row.id)
      assert reason =~ "unknown-repo"
    end

    test "a proposal with no repo attribution fails cleanly, naming the gap", %{ws: ws} do
      {:ok, row} = Loop.record(candidate(ws, %{repo: nil, target: nil}))

      assert {:error, {:unmapped, reason}} = Loop.apply_pending(row.id)
      assert reason =~ "no repo"
    end
  end
end
