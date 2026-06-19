defmodule Arbiter.Polecat.ResumeContext do
  @moduledoc """
  Build the "work so far" briefing for a **resumed** worker (bd-auma3z).

  When a worker is stopped mid-work (token exhaustion, crash, kill) its
  per-bead git worktree is preserved on disk: any commits it
  made are on the branch, and any in-flight edits sit uncommitted in the tree.
  Re-dispatching from scratch would discard that history from the agent's context
  and risk redoing or duplicating completed steps.

  This module reads the **git state of the preserved worktree** and renders a
  Markdown prefix that is prepended to the standard work prompt by
  `Arbiter.Polecat.Dispatch`. The resumed (fresh) agent reads it and continues
  from where the prior one left off.

  ## Provider-agnostic by construction

  The briefing is plain text derived from `git` — no Claude/Gemini session id,
  no provider `--resume` flag. Any agent, on any provider, gets the same
  worktree-state summary. This is the deliberate design choice (Admiral sign-off
  2026-06-05): approach (b) — reattach a fresh agent to the preserved worktree
  with a git-derived briefing — over approach (a) provider session-resume.

  ## What's in the briefing

    * **Commits since the branch was cut** — `git log --oneline <base>..HEAD`,
      so the agent sees the completed, committed work.
    * **Uncommitted changes** — `git status --porcelain` plus a bounded
      `git diff HEAD`, so the agent sees in-flight edits that were never
      committed (the most common stop state).

  Both are bounded so a large diff can't blow up the prompt: the diff is capped
  at `@max_diff_lines` lines.
  """

  alias Arbiter.Beads.Issue
  alias Arbiter.Polecat.Worktree

  # Cap the embedded `git diff HEAD` so a resumed worker that left a huge
  # uncommitted change doesn't produce a multi-megabyte prompt. The agent can
  # always run `git diff` itself in the worktree for the full picture; the
  # briefing only needs to orient it.
  @max_diff_lines 400

  @doc """
  Build the resume briefing for `bead` from the worktree at `worktree_path`,
  diffing against `base_branch`.

  Returns `{:ok, prefix}` where `prefix` is the Markdown block to prepend to
  the work prompt, or `{:error, :no_outpost}` when the worktree directory does
  not exist on disk (nothing to resume — the caller should refuse the resume
  rather than silently restart from scratch).
  """
  @spec build(Issue.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :no_outpost}
  def build(%Issue{} = bead, worktree_path, base_branch)
      when is_binary(worktree_path) and is_binary(base_branch) do
    if File.dir?(worktree_path) do
      {:ok, render(bead, worktree_path, base_branch)}
    else
      {:error, :no_outpost}
    end
  end

  defp render(%Issue{id: id}, worktree_path, base_branch) do
    """
    You are RESUMING work on bead #{id}. A prior worker was working this bead
    in this same git worktree (your current directory) but stopped before
    finishing. Its work is preserved here — DO NOT start over or redo steps that
    are already done. Read the state below, verify it, and continue from there.

    #{work_so_far(worktree_path, base_branch)}
    Continue from where the prior worker left off: finish the remaining work,
    commit it on this branch, and complete the bead as usual. If commits or
    uncommitted changes above already satisfy part of the acceptance, do not
    redo them — build on them.

    ─────────────────────────────────────────────────────────────────────────

    """
  end

  @doc """
  Render just the git-state "work so far" briefing — the commits made since the
  branch was cut plus any uncommitted work-in-progress — as a Markdown block,
  WITHOUT the surrounding resume framing.

  Split out of `build/3` so callers other than the `arb resume` path can reuse
  the same git-derived continuity briefing. The ReviewGate's revise-and-rediscuss
  loop (bd-1na62i, Stage 3) prepends it to a revise-round implementer: between
  review rounds the prior round's fixes are committed on the branch (and any
  stragglers sit uncommitted), and the fresh implementer mind needs that picture
  to *continue the thread* rather than re-derive it from a raw diff. This is the
  provider-agnostic same-mind-continuity approximation Stage 3 settled on — git
  state, not a Claude/Gemini session-resume id.
  """
  @spec work_so_far(String.t(), String.t()) :: String.t()
  def work_so_far(worktree_path, base_branch)
      when is_binary(worktree_path) and is_binary(base_branch) do
    """
    ## Work already committed (git log #{base_branch}..HEAD)
    #{commits_block(worktree_path, base_branch)}

    ## Uncommitted work-in-progress in the worktree
    #{uncommitted_block(worktree_path)}
    """
  end

  # `git log --oneline <base>..HEAD` — the commits the prior worker made on the
  # per-bead branch since it diverged from the integration branch.
  defp commits_block(worktree_path, base_branch) do
    case run_git(["log", "--oneline", "#{base_branch}..HEAD"], worktree_path) do
      {:ok, ""} -> "(no commits yet — the prior worker committed nothing)"
      {:ok, out} -> fenced(out)
      {:error, _} -> "(could not read git log)"
    end
  end

  # `git status --porcelain` + a bounded `git diff HEAD`. The status lists which
  # files changed; the diff shows the actual edits. Build-artifact noise
  # (`deps`, `_build`) is filtered the same way the commit gate filters it.
  defp uncommitted_block(worktree_path) do
    case Worktree.has_uncommitted?(worktree_path) do
      {:ok, false} ->
        "(working tree clean — no uncommitted changes)"

      {:ok, true} ->
        status = status_block(worktree_path)
        diff = diff_block(worktree_path)
        "Changed files:\n#{status}\n\nDiff (capped at #{@max_diff_lines} lines):\n#{diff}"

      {:error, _} ->
        "(could not read git status)"
    end
  end

  defp status_block(worktree_path) do
    case run_git(["status", "--short"], worktree_path) do
      {:ok, ""} -> "(none)"
      {:ok, out} -> fenced(out)
      {:error, _} -> "(could not read git status)"
    end
  end

  defp diff_block(worktree_path) do
    case run_git(["diff", "HEAD"], worktree_path) do
      {:ok, ""} ->
        "(no tracked-file diff; changes may be untracked new files — see the file list above)"

      {:ok, out} ->
        out
        |> String.split("\n")
        |> cap_lines()
        |> Enum.join("\n")
        |> fenced()

      {:error, _} ->
        "(could not read git diff)"
    end
  end

  defp cap_lines(lines) when length(lines) <= @max_diff_lines, do: lines

  defp cap_lines(lines) do
    Enum.take(lines, @max_diff_lines) ++
      ["… (diff truncated at #{@max_diff_lines} lines — run `git diff` for the rest)"]
  end

  defp fenced(content), do: "```\n#{String.trim_trailing(content)}\n```"

  defp run_git(args, cd) do
    case System.cmd("git", args, stderr_to_stdout: true, cd: cd) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _nonzero} -> {:error, String.trim(output)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
