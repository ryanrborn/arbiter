defmodule Arbiter.Workflows.CodeReview do
  @moduledoc """
  Peer-review workflow (gte-021). The Elixir port of Go GT's
  `mol-polecat-code-review` formula.

  Reviews a branch's diff against a bead's acceptance criteria and produces
  a verdict (`:approve` or `:request_changes`). Two modes:

    * `:local`  — writes `reviews/<branch>.md` in the worktree.
    * `:github` — posts inline comments + a top-level review via the
      `Arbiter.GitHub` HTTP client (no `gh` shell-out).

  ## Steps

  1. `:load_pr`       — record branch / load PR metadata
  2. `:read_diff`     — `git diff <base>..HEAD` against the worktree
  3. `:run_checks`    — invoke the `:check_runner` to produce findings
  4. `:file_findings` — write the review file (local) or post comments (github)
  5. `:verdict`       — compute approve / request_changes; finalize

  ## State

      %{
        repo: "owner/name",          # github mode only
        pr_number: integer | nil,
        worktree_path: "/path/to/worktree",
        mode: :local | :github,
        base: "main",                # diff base; default "main"
        bead: %{id: _, title: _},    # optional, only used in the report header
        check_runner: fun | nil,     # 2-arity (diff, state) -> {:ok, findings}
        github_opts: keyword(),      # forwarded to Arbiter.GitHub.* calls
        # Populated as steps run:
        pr: map() | nil,
        branch: String.t(),
        diff: String.t(),
        findings: [Checks.finding()],
        verdict: :approve | :request_changes,
        review_path: String.t() | nil  # local mode only
      }

  ## Forbidden actions

  A reviewer polecat MUST NOT:

    * push code (no `Polecat.Worktree.push/2` call lives in this workflow)
    * merge PRs (no `GitHub.pr_merge/4` call lives in this workflow)
    * make non-comment GitHub mutations beyond inline comments + a single review

  These constraints are enforced **statically** (this module simply does not
  call those functions) and documented here. If a reviewer is uncertain it
  escalates to the Admiral via the surrounding orchestration — the workflow
  itself just produces a verdict and stops.

  After `:verdict` runs, control returns to the polecat which transitions
  back to `:idle`. The workflow does not drive the polecat state directly.

  ## Extending checks

  Real check logic is a follow-up. To plug in checks, set `state.check_runner`
  to a 2-arity function `(diff, state) -> {:ok, [finding]} | {:error, term}`.
  Default runner returns `{:ok, []}` (see
  `Arbiter.Workflows.CodeReview.Checks`).
  """

  use Arbiter.Workflow,
    steps: [:load_pr, :read_diff, :run_checks, :file_findings, :verdict]

  alias Arbiter.GitHub
  alias Arbiter.Polecat.Worktree
  alias Arbiter.Workflows.CodeReview.{Checks, GithubMode, LocalMode}

  step(:load_pr,
    description: "Load PR metadata (github) or record branch (local)",
    needs: [],
    vars: [:repo, :pr_number, :worktree_path, :mode]
  )

  step(:read_diff, description: "Read the branch diff vs base", needs: [:load_pr], vars: [:base])

  step(:run_checks,
    description: "Run automated checks against the diff",
    needs: [:read_diff],
    vars: [:check_runner]
  )

  step(:file_findings,
    description: "Write review file (local) or post comments (github)",
    needs: [:run_checks],
    vars: [:bead]
  )

  step(:verdict,
    description: "Approve or request_changes based on findings",
    needs: [:file_findings],
    vars: []
  )

  # ---- :load_pr ----------------------------------------------------------

  @impl Arbiter.Workflow
  def run_step(:load_pr, %{mode: :local, worktree_path: wt} = state) when is_binary(wt) do
    case Worktree.current_branch(wt) do
      {:ok, branch} -> {:ok, state |> Map.put(:branch, branch) |> Map.put(:pr, nil)}
      {:error, _} = err -> err
    end
  end

  def run_step(:load_pr, %{mode: :github, repo: repo, pr_number: n} = state)
      when is_binary(repo) and is_integer(n) do
    opts = Map.get(state, :github_opts, [])

    case GitHub.pr_get(repo, n, opts) do
      {:ok, pr} ->
        branch = get_in(pr, ["head", "ref"]) || ""
        {:ok, state |> Map.put(:pr, pr) |> Map.put(:branch, branch)}

      {:error, _} = err ->
        err
    end
  end

  def run_step(:load_pr, state) do
    {:error,
     {:bad_state,
      "load_pr requires :mode + :worktree_path (local) or :repo+:pr_number (github), got: #{inspect(Map.take(state, [:mode, :worktree_path, :repo, :pr_number]))}"}}
  end

  # ---- :read_diff --------------------------------------------------------

  def run_step(:read_diff, %{worktree_path: wt} = state) when is_binary(wt) do
    base = Map.get(state, :base, "main")

    case System.cmd("git", ["-C", wt, "diff", "#{base}..HEAD"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, Map.put(state, :diff, output)}
      {output, _nonzero} -> {:error, {:git_diff_failed, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:git_diff_failed, Exception.message(e)}}
  end

  def run_step(:read_diff, _state),
    do: {:error, {:bad_state, "read_diff requires :worktree_path"}}

  # ---- :run_checks -------------------------------------------------------

  def run_step(:run_checks, state) do
    diff = Map.get(state, :diff, "")
    runner = Map.get(state, :check_runner) || (&Checks.run/2)

    case runner.(diff, state) do
      {:ok, findings} when is_list(findings) ->
        {:ok, Map.put(state, :findings, findings)}

      {:error, _} = err ->
        err

      other ->
        {:error, {:bad_check_runner_return, other}}
    end
  end

  # ---- :file_findings ----------------------------------------------------

  def run_step(:file_findings, %{mode: :local, worktree_path: wt, branch: branch} = state) do
    findings = Map.get(state, :findings, [])
    bead = Map.get(state, :bead)
    :ok = LocalMode.write_findings(wt, branch, bead, findings)
    {:ok, Map.put(state, :review_path, LocalMode.review_path(wt, branch))}
  end

  def run_step(:file_findings, %{mode: :github, repo: repo, pr_number: n} = state) do
    findings = Map.get(state, :findings, [])
    opts = Map.get(state, :github_opts, [])

    case GithubMode.post_findings(repo, n, findings, opts) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  def run_step(:file_findings, _state),
    do: {:error, {:bad_state, "file_findings: unknown mode"}}

  # ---- :verdict ----------------------------------------------------------

  def run_step(:verdict, %{mode: :local} = state) do
    verdict = compute_verdict(Map.get(state, :findings, []))
    path = Map.fetch!(state, :review_path)
    :ok = LocalMode.set_verdict(path, verdict)
    {:ok, Map.put(state, :verdict, verdict)}
  end

  def run_step(:verdict, %{mode: :github, repo: repo, pr_number: n} = state) do
    findings = Map.get(state, :findings, [])
    verdict = compute_verdict(findings)
    opts = Map.get(state, :github_opts, [])
    body = verdict_summary(verdict, findings)

    case GithubMode.post_verdict(repo, n, verdict, body, opts) do
      {:ok, _} -> {:ok, Map.put(state, :verdict, verdict)}
      {:error, _} = err -> err
    end
  end

  def run_step(:verdict, _state), do: {:error, {:bad_state, "verdict: unknown mode"}}

  # ---- helpers -----------------------------------------------------------

  @doc false
  @spec compute_verdict([Checks.finding()]) :: :approve | :request_changes
  def compute_verdict(findings) when is_list(findings) do
    if Enum.any?(findings, &(&1[:severity] == :error)) do
      :request_changes
    else
      :approve
    end
  end

  defp verdict_summary(:approve, []), do: "Approved: no findings."

  defp verdict_summary(:approve, findings),
    do: "Approved with #{length(findings)} non-blocking finding(s)."

  defp verdict_summary(:request_changes, findings) do
    errors = Enum.count(findings, &(&1[:severity] == :error))
    "Requesting changes: #{errors} blocking finding(s) out of #{length(findings)}."
  end
end
