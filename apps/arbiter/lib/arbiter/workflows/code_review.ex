defmodule Arbiter.Workflows.CodeReview do
  @moduledoc """
  Peer-review workflow (gte-021). The Elixir port of Go GT's
  `mol-worker-code-review` formula.

  Reviews a PR/MR's diff against a task's acceptance criteria and produces
  a verdict (`:approve` or `:request_changes`). Two modes:

    * `:local`    — writes `reviews/<branch>.md` in a local worktree.
    * `:adapter`  — dispatches every side-effect through an
      `Arbiter.Mergers.Merger` adapter (Direct / GitLab / GitHub), so a
      review can run against an arbitrary PR/MR — including ones the fleet
      did not author — through the configured tracker.

  ## Report-only (a.k.a. propose) reviews (bd-36qzgx)

  When `report_only: true` is set on the state (adapter mode only), the workflow
  runs the *full* review — read the diff, compute findings, compute the verdict —
  but posts **NOTHING** to the PR. Instead of calling `post_inline_comment` /
  `submit_review`, `:file_findings` captures the per-finding **proposed comment
  text** under `:proposed_comments` and `:verdict` captures the *recommended*
  verdict + summary under `:verdict` / `:proposed_review_body`. A caller
  (`Arbiter.Reviews.ExternalReview`) then surfaces these to the coordinator, who
  greenlights which comments actually post. This is the human-in-the-loop review
  path required for infra repos.

  ## Steps

  1. `:load_pr`       — record branch / load PR metadata (no-op in `:adapter` mode)
  2. `:read_diff`     — fetch the diff via the adapter (or `git diff` locally)
  3. `:run_checks`    — invoke the `:check_runner` to produce findings
  4. `:file_findings` — write the review file (local) or post comments (adapter)
  5. `:verdict`       — compute approve / request_changes; finalize

  ## State

      %{
        mode: :local | :adapter,

        # :local mode requires:
        worktree_path: "/path/to/worktree",
        base: "main",                # diff base; default "main"

        # :adapter mode requires:
        adapter: module(),           # an Arbiter.Mergers.Merger impl
        mr_ref: String.t(),          # opaque ref minted by the adapter
        workspace: Workspace.t() | nil,  # when set, Mergers.prepare/1 is called
        adapter_opts: %{...},        # forwarded to every adapter call

        # Common:
        task: %{id: _, title: _},    # optional, included in the file/notes
        check_runner: fun | nil,     # 2-arity (diff, state) -> {:ok, findings}
        report_only: boolean(),      # adapter mode: review but post nothing (bd-36qzgx)

        # Populated as steps run:
        branch: String.t() | nil,
        diff: String.t(),
        findings: [Checks.finding()],
        verdict: :approve | :request_changes,
        review_path: String.t() | nil  # populated by the local file mode
      }

  ## Default check runner

  Without an explicit `:check_runner`, `Arbiter.Workflows.CodeReview.Checks`
  runs a Claude session on the diff and parses structured findings from its
  JSON output. Tests can short-circuit Claude by passing a stub runner via
  `state.check_runner`.

  ## Forbidden actions

  A reviewer worker MUST NOT:

    * push code (no `Worker.Worktree.push/2` call lives in this workflow)
    * merge PRs (no `GitHub.pr_merge/4` / `Merger.merge/1` call lives here)
    * make non-comment mutations beyond inline comments + a single review

  These constraints are enforced **statically** (this module simply does
  not call those functions) and documented here.

  After `:verdict` runs, control returns to the worker which transitions
  back to `:idle`. The workflow does not drive the worker state directly.
  """

  use Arbiter.Workflow,
    steps: [:load_pr, :read_diff, :run_checks, :file_findings, :verdict]

  alias Arbiter.Mergers
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workflows.CodeReview.{Checks, ConsumerTrace, LocalMode}

  step(:load_pr,
    description: "Record branch (local) or accept adapter mr_ref (adapter)",
    needs: [],
    vars: [:worktree_path, :mode, :adapter, :mr_ref]
  )

  step(:read_diff,
    description: "Read the diff via the adapter or local git",
    needs: [:load_pr],
    vars: [:base, :adapter_opts]
  )

  step(:run_checks,
    description: "Run automated checks against the diff",
    needs: [:read_diff],
    vars: [:check_runner]
  )

  step(:file_findings,
    description: "Write review file (local) or post comments (adapter)",
    needs: [:run_checks],
    vars: [:task]
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

  def run_step(:load_pr, %{mode: :adapter, adapter: adapter, mr_ref: mr_ref} = state)
      when is_atom(adapter) and is_binary(mr_ref) do
    prepare_adapter(state)

    case safe_adapter_call(adapter, :get, [mr_ref]) do
      {:ok, info} ->
        branch = Map.get(info, :branch) || Map.get(info, "branch")
        {:ok, state |> Map.put(:pr, info) |> Map.put(:branch, branch)}

      # Adapters whose `get/1` doesn't surface a branch (Direct, GitLab in
      # the abbreviated task-domain view) still let the workflow proceed —
      # the branch isn't load-bearing for any later step in :adapter mode.
      {:error, _} ->
        {:ok, state |> Map.put(:pr, nil) |> Map.put(:branch, nil)}
    end
  end

  def run_step(:load_pr, state) do
    {:error,
     {:bad_state,
      "load_pr requires :mode + :worktree_path (local) or :adapter + :mr_ref (adapter), got: " <>
        inspect(Map.take(state, [:mode, :worktree_path, :adapter, :mr_ref]))}}
  end

  # ---- :read_diff --------------------------------------------------------

  def run_step(:read_diff, %{mode: :local, worktree_path: wt} = state) when is_binary(wt) do
    base = Map.get(state, :base, "main")

    case System.cmd("git", ["-C", wt, "diff", "#{base}..HEAD"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, Map.put(state, :diff, output)}
      {output, _nonzero} -> {:error, {:git_diff_failed, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:git_diff_failed, Exception.message(e)}}
  end

  def run_step(:read_diff, %{mode: :adapter, adapter: adapter, mr_ref: mr_ref} = state)
      when is_atom(adapter) and is_binary(mr_ref) do
    prepare_adapter(state)
    opts = adapter_opts(state)

    case safe_adapter_call(adapter, :get_diff, [mr_ref, opts]) do
      {:ok, diff} when is_binary(diff) -> {:ok, Map.put(state, :diff, diff)}
      {:error, _} = err -> err
    end
  end

  def run_step(:read_diff, _state),
    do: {:error, {:bad_state, "read_diff requires :worktree_path (local) or :adapter+:mr_ref"}}

  # ---- :run_checks -------------------------------------------------------

  def run_step(:run_checks, state) do
    diff = Map.get(state, :diff, "")
    runner = Map.get(state, :check_runner) || (&Checks.run/2)
    state = maybe_add_consumer_refs(state, diff)

    case runner.(diff, state) do
      {:ok, findings} when is_list(findings) ->
        {:ok, Map.put(state, :findings, findings)}

      {:ok, findings, usage} when is_list(findings) ->
        {:ok, state |> Map.put(:findings, findings) |> Map.put(:check_usage, usage)}

      {:error, _} = err ->
        err

      other ->
        {:error, {:bad_check_runner_return, other}}
    end
  end

  # ---- :file_findings ----------------------------------------------------

  def run_step(:file_findings, %{mode: :local, worktree_path: wt, branch: branch} = state) do
    findings = Map.get(state, :findings, [])
    task = Map.get(state, :task)
    :ok = LocalMode.write_findings(wt, branch, task, findings)
    {:ok, Map.put(state, :review_path, LocalMode.review_path(wt, branch))}
  end

  # Report-only: capture the per-finding proposed comment text and post NOTHING.
  # This clause must precede the posting clause below.
  def run_step(:file_findings, %{mode: :adapter, report_only: true} = state) do
    proposed =
      state
      |> Map.get(:findings, [])
      |> Enum.map(&proposed_comment/1)

    {:ok, Map.put(state, :proposed_comments, proposed)}
  end

  def run_step(:file_findings, %{mode: :adapter, adapter: adapter, mr_ref: mr_ref} = state)
      when is_atom(adapter) and is_binary(mr_ref) do
    prepare_adapter(state)
    findings = Map.get(state, :findings, [])
    opts = adapter_opts(state)

    # Inline comments are the per-finding artifact; the verdict step posts
    # the single review-level summary via submit_review/4. No separate
    # add_comment call — that would double-post on hosted forges where
    # submit_review already carries a body.
    post_each_finding(adapter, mr_ref, findings, opts, state)
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

  # Report-only: compute the recommended verdict + summary and post NOTHING.
  # This clause must precede the submitting clause below.
  def run_step(:verdict, %{mode: :adapter, report_only: true} = state) do
    findings = Map.get(state, :findings, [])
    verdict = compute_verdict(findings)
    body = verdict_summary(verdict, findings)

    {:ok,
     state
     |> Map.put(:verdict, verdict)
     |> Map.put(:proposed_review_body, body)}
  end

  def run_step(:verdict, %{mode: :adapter, adapter: adapter, mr_ref: mr_ref} = state)
      when is_atom(adapter) and is_binary(mr_ref) do
    prepare_adapter(state)
    findings = Map.get(state, :findings, [])
    verdict = compute_verdict(findings)
    body = verdict_summary(verdict, findings)
    opts = adapter_opts(state)

    case safe_adapter_call(adapter, :submit_review, [mr_ref, verdict, body, opts]) do
      {:ok, response} ->
        {:ok,
         state
         |> Map.put(:verdict, verdict)
         |> maybe_capture_path(response)}

      {:error, _} = err ->
        err
    end
  end

  def run_step(:verdict, _state), do: {:error, {:bad_state, "verdict: unknown mode"}}

  # ---- scope resolution / consumer trace ---------------------------------

  # Repo-scoped reviews get a deterministic cross-file consumer trace (see
  # `ConsumerTrace` moduledoc for why this isn't just handed to the LLM as
  # filesystem access). Diff scope (the default) never touches disk here.
  defp maybe_add_consumer_refs(%{repo_path: repo_path} = state, diff) when is_binary(repo_path) do
    if effective_scope(state, diff) == :repo do
      Map.put(state, :consumer_refs, ConsumerTrace.trace(diff, repo_path))
    else
      state
    end
  end

  defp maybe_add_consumer_refs(state, _diff), do: state

  # Explicit `:scope` wins; otherwise a changed file matching any of
  # `:sensitive_globs` (workspace `review_scope.sensitive_globs`, resolved by
  # the caller) auto-escalates a security/cross-cutting PR to repo scope.
  defp effective_scope(%{scope: :repo}, _diff), do: :repo

  defp effective_scope(state, diff) do
    globs = Map.get(state, :sensitive_globs) || []

    if globs != [] and touches_sensitive_path?(diff, globs) do
      :repo
    else
      Map.get(state, :scope, :diff)
    end
  end

  defp touches_sensitive_path?(diff, globs) do
    diff
    |> ConsumerTrace.changed_files()
    |> Enum.any?(fn file -> Enum.any?(globs, &Arbiter.Worker.ReviewScope.glob_match?(&1, file)) end)
  end

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

  @doc """
  Build the report-only "proposed comment" for a single finding: the finding's
  `file` / `line` / `severity` / `message`, plus `body` — the exact inline
  comment text that would be posted on the PR (mirrors the hosted adapters'
  `post_inline_comment` body format). The greenlight step re-posts the selected
  subset of these verbatim.
  """
  @spec proposed_comment(Checks.finding()) :: map()
  def proposed_comment(%{} = finding) do
    %{
      file: finding[:file] || finding["file"],
      line: finding[:line] || finding["line"],
      severity: finding[:severity] || finding["severity"],
      message: finding[:message] || finding["message"],
      body: finding_comment_body(finding)
    }
  end

  @doc "The inline-comment body text for a finding (`**SEVERITY**: message`)."
  @spec finding_comment_body(map()) :: String.t()
  def finding_comment_body(%{} = finding) do
    sev = finding[:severity] || finding["severity"]
    msg = finding[:message] || finding["message"] || ""
    "**#{severity_label(sev)}**: #{msg}"
  end

  defp severity_label(:info), do: "INFO"
  defp severity_label(:warning), do: "WARNING"
  defp severity_label(:error), do: "ERROR"
  defp severity_label(nil), do: "INFO"
  defp severity_label(other), do: other |> to_string() |> String.upcase()

  defp verdict_summary(:approve, []), do: "Approved: no findings."

  defp verdict_summary(:approve, findings),
    do: "Approved with #{length(findings)} non-blocking finding(s)."

  defp verdict_summary(:request_changes, findings) do
    errors = Enum.count(findings, &(&1[:severity] == :error))
    "Requesting changes: #{errors} blocking finding(s) out of #{length(findings)}."
  end

  defp post_each_finding(adapter, mr_ref, findings, opts, state) do
    Enum.reduce_while(findings, {:ok, state}, fn finding, {:ok, acc} ->
      case safe_adapter_call(adapter, :post_inline_comment, [mr_ref, finding, opts]) do
        {:ok, response} -> {:cont, {:ok, maybe_capture_path(acc, response)}}
        :ok -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Some adapters (Direct) write findings to a local file and return its
  # path. Expose that on the state so callers can locate the artifact.
  defp maybe_capture_path(state, %{path: path}) when is_binary(path),
    do: Map.put_new(state, :review_path, path)

  defp maybe_capture_path(state, _), do: state

  defp adapter_opts(state) do
    state
    |> Map.get(:adapter_opts, %{})
    |> Map.put_new(:task, Map.get(state, :task))
  end

  # Adapters that need workspace-scoped per-process state (Github, Gitlab)
  # have their `prepare/1` invoked by `Arbiter.Mergers.prepare/1` before any
  # adapter call. The workflow forwards the workspace once at the start of
  # every step — adapters that don't need it (Direct) ignore the call.
  defp prepare_adapter(%{workspace: ws}) when not is_nil(ws), do: Mergers.prepare(ws)
  defp prepare_adapter(_), do: :ok

  defp safe_adapter_call(adapter, fun, args) do
    apply(adapter, fun, args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
