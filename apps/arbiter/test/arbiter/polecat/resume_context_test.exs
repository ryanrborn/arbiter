defmodule Arbiter.Polecat.ResumeContextTest do
  use ExUnit.Case, async: true

  alias Arbiter.Beads.Issue
  alias Arbiter.Polecat.ResumeContext

  setup do
    tmp = Path.join(System.tmp_dir!(), "resume-ctx-#{:erlang.unique_integer([:positive])}")
    repo = Path.join(tmp, "wt")
    File.mkdir_p!(repo)

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-q", "-m", "base commit on main"])

    # Cut the per-bead branch from main, so `main..HEAD` is meaningful.
    git!(repo, ["checkout", "-q", "-b", "feature/bd-test"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo, bead: %Issue{id: "bd-test", title: "resume me"}}
  end

  defp git!(repo, args) do
    {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    :ok
  end

  test "returns {:error, :no_outpost} when the worktree dir is missing", %{bead: bead} do
    assert {:error, :no_outpost} =
             ResumeContext.build(bead, "/nonexistent/path/abc123", "main")
  end

  test "summarizes committed work since the branch was cut", %{repo: repo, bead: bead} do
    File.write!(Path.join(repo, "feature.ex"), "defmodule F, do: nil\n")
    git!(repo, ["add", "feature.ex"])
    git!(repo, ["commit", "-q", "-m", "add the feature scaffold"])

    assert {:ok, prefix} = ResumeContext.build(bead, repo, "main")

    assert prefix =~ "RESUMING work on bead bd-test"
    assert prefix =~ "add the feature scaffold"
    assert prefix =~ "working tree clean"
    # The base-branch commit must NOT appear — only commits ahead of main.
    refute prefix =~ "base commit on main"
  end

  test "surfaces uncommitted work-in-progress (tracked edits)", %{repo: repo, bead: bead} do
    # Modify a tracked file but do not commit it.
    File.write!(Path.join(repo, "README.md"), "base\nWORK IN PROGRESS LINE\n")

    assert {:ok, prefix} = ResumeContext.build(bead, repo, "main")

    assert prefix =~ "Uncommitted work-in-progress"
    assert prefix =~ "README.md"
    assert prefix =~ "WORK IN PROGRESS LINE"
  end

  test "reports a clean tree with no commits when nothing was done", %{repo: repo, bead: bead} do
    assert {:ok, prefix} = ResumeContext.build(bead, repo, "main")

    assert prefix =~ "no commits yet"
    assert prefix =~ "working tree clean"
  end

  test "caps an enormous diff so the prompt stays bounded", %{repo: repo, bead: bead} do
    big = Enum.map_join(1..2000, "\n", &"line #{&1}")
    File.write!(Path.join(repo, "README.md"), big)

    assert {:ok, prefix} = ResumeContext.build(bead, repo, "main")
    assert prefix =~ "diff truncated"
  end

  # `work_so_far/2` is the reusable git-state body shared with the ReviewGate's
  # revise loop (bd-1na62i). It returns just the committed/uncommitted blocks,
  # WITHOUT the "RESUMING work" framing that wraps it in `build/3`.
  test "work_so_far/2 renders the git-state blocks without the resume framing",
       %{repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "defmodule F, do: nil\n")
    git!(repo, ["add", "feature.ex"])
    git!(repo, ["commit", "-q", "-m", "add the feature scaffold"])
    File.write!(Path.join(repo, "README.md"), "base\nWIP\n")

    briefing = ResumeContext.work_so_far(repo, "main")

    assert briefing =~ "Work already committed"
    assert briefing =~ "add the feature scaffold"
    assert briefing =~ "Uncommitted work-in-progress"
    assert briefing =~ "WIP"
    # The resume-specific framing belongs to build/3, not the shared body.
    refute briefing =~ "RESUMING work on bead"
  end
end
