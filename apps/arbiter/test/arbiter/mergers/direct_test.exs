defmodule Arbiter.Mergers.DirectTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.Direct

  describe "open/4 against a real git repo" do
    @tag :tmp_dir
    test "merges the feature branch into target with a --no-ff merge commit", %{tmp_dir: dir} do
      build_repo(dir)

      assert {:ok, "direct:feature/x"} =
               Direct.open("feature/x", "Merge feature/x", "", %{
                 repo_path: dir,
                 target_branch: "main"
               })

      # The feature branch's file is now present on main.
      assert File.exists?(Path.join(dir, "feature.txt"))

      # HEAD is on main, and the tip is a merge commit (two parents) thanks to --no-ff.
      assert {"main\n", 0} = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
      assert {parents, 0} = git(dir, ["rev-list", "--parents", "-n", "1", "HEAD"])
      assert length(String.split(String.trim(parents), " ")) == 3

      # The merge commit carries the title we passed as the message.
      assert {subject, 0} = git(dir, ["log", "-1", "--pretty=%s"])
      assert String.trim(subject) == "Merge feature/x"
    end

    @tag :tmp_dir
    test "defaults target_branch to main when omitted", %{tmp_dir: dir} do
      build_repo(dir)
      # Move off main so we can prove open/4 checks main back out itself.
      assert {_, 0} = git(dir, ["checkout", "feature/x"])

      assert {:ok, "direct:feature/x"} =
               Direct.open("feature/x", "", "", %{repo_path: dir})

      assert {"main\n", 0} = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
      assert File.exists?(Path.join(dir, "feature.txt"))
    end

    @tag :tmp_dir
    test "returns an error when the branch does not exist", %{tmp_dir: dir} do
      build_repo(dir)

      assert {:error, {:git_failed, _msg}} =
               Direct.open("nope/missing", "", "", %{repo_path: dir, target_branch: "main"})
    end

    test "returns {:error, :no_repo_path} when repo_path is absent" do
      assert {:error, :no_repo_path} = Direct.open("feature/x", "", "", %{target_branch: "main"})
    end
  end

  describe "open/4 on a conflicting merge (bd-1rhyla)" do
    # A conflicting auto-merge once left the canonical tree half-merged and
    # uncompilable, wedging the live server. open/4 MUST abort the merge so the
    # tree stays clean + compilable, and report the conflicting files.
    @tag :tmp_dir
    test "aborts the merge, leaves main clean + unchanged, and names the conflicting files",
         %{tmp_dir: dir} do
      build_conflict_repo(dir)

      # Tip of main before the attempted merge — must be unchanged afterward.
      {head_before, 0} = git(dir, ["rev-parse", "HEAD"])

      assert {:error, {:merge_conflict, detail}} =
               Direct.open("feature/conflict", "Merge feature/conflict", "", %{
                 repo_path: dir,
                 target_branch: "main"
               })

      assert detail.branch == "feature/conflict"
      assert "shared.txt" in detail.files
      assert is_binary(detail.output)

      # The merge was aborted: HEAD is still main, at the same commit, and the
      # working tree is clean (no conflict markers, no unmerged paths) — the
      # canonical checkout the live server compiles from is intact.
      assert {"main\n", 0} = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
      assert {^head_before, 0} = git(dir, ["rev-parse", "HEAD"])
      assert {"", 0} = git(dir, ["status", "--porcelain"])
      assert {"", 0} = git(dir, ["diff", "--name-only", "--diff-filter=U"])
      refute File.read!(Path.join(dir, "shared.txt")) =~ "<<<<<<<"
    end
  end

  describe "no-op / constant callbacks" do
    test "get/1 always reports :merged" do
      assert Direct.get("direct:anything") == {:ok, %{status: :merged}}
    end

    test "merge/1, close/1, add_comment/2, request_review/2 are :ok no-ops" do
      assert Direct.merge("direct:x") == :ok
      assert Direct.close("direct:x") == :ok
      assert Direct.add_comment("direct:x", "hello") == :ok
      assert Direct.request_review("direct:x", [1, 2]) == :ok
    end

    test "link_for/1 returns an empty string" do
      assert Direct.link_for("direct:x") == ""
    end
  end

  test "module declares the Merger behaviour" do
    behaviours =
      Direct.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Arbiter.Mergers.Merger in behaviours
  end

  # ---- helpers ----

  # Builds a repo with `main` (one commit) and a `feature/x` branch that adds
  # feature.txt on top of it. Leaves HEAD on main.
  defp build_repo(dir) do
    {_, 0} = git(dir, ["init", "-q"])
    {_, 0} = git(dir, ["config", "user.email", "worker@example.test"])
    {_, 0} = git(dir, ["config", "user.name", "Worker"])
    {_, 0} = git(dir, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(dir, "base.txt"), "base\n")
    {_, 0} = git(dir, ["add", "base.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "init"])
    # Normalize the default branch name across git versions.
    {_, 0} = git(dir, ["branch", "-M", "main"])

    {_, 0} = git(dir, ["checkout", "-q", "-b", "feature/x"])
    File.write!(Path.join(dir, "feature.txt"), "feature\n")
    {_, 0} = git(dir, ["add", "feature.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "add feature"])

    {_, 0} = git(dir, ["checkout", "-q", "main"])
  end

  # Builds a repo where `main` and `feature/conflict` both modify the same line
  # of shared.txt, so a `--no-ff` merge conflicts. Leaves HEAD on main.
  defp build_conflict_repo(dir) do
    {_, 0} = git(dir, ["init", "-q"])
    {_, 0} = git(dir, ["config", "user.email", "worker@example.test"])
    {_, 0} = git(dir, ["config", "user.name", "Worker"])
    {_, 0} = git(dir, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(dir, "shared.txt"), "original\n")
    {_, 0} = git(dir, ["add", "shared.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "init"])
    {_, 0} = git(dir, ["branch", "-M", "main"])

    # Diverging change on the feature branch.
    {_, 0} = git(dir, ["checkout", "-q", "-b", "feature/conflict"])
    File.write!(Path.join(dir, "shared.txt"), "from feature\n")
    {_, 0} = git(dir, ["add", "shared.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "feature change"])

    # Conflicting change on main.
    {_, 0} = git(dir, ["checkout", "-q", "main"])
    File.write!(Path.join(dir, "shared.txt"), "from main\n")
    {_, 0} = git(dir, ["add", "shared.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "main change"])
  end

  defp git(dir, args), do: System.cmd("git", args, stderr_to_stdout: true, cd: dir)
end
