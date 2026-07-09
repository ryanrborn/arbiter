defmodule Arbiter.Workflows.MergeQueue.FixPassDispatcher do
  @moduledoc """
  Spawn a short-lived worker to fix a `:ci_failed` PR — diagnose the failing
  checks, fix the root cause, and push back to the **same branch** so CI re-runs
  (#354, Phase 2a).

  Invoked by `Arbiter.Worker.Watchdog` when an approved PR is
  blocked because its required checks are failing. Before this, the Watchdog only
  *escalated* a `:ci_failed` block to the Admiral and parked the PR; the fix-pass
  dispatcher lets the common, mechanically-fixable failures (a broken test, a
  formatting violation, a missing compile fix) unblock themselves.

  ## Job scope

  The worker is given a *narrowly* constrained prompt: read the failing check
  names + log tails (handed to it in the briefing), fix the root cause, commit,
  and push to the existing branch with the existing PR updating in place. It must
  NOT re-implement the change set or open a new PR. When the failure isn't
  something it can fix (an infrastructure/flake failure, or a failure it can't
  reproduce) it escalates via the workspace mailbox rather than thrashing.

  ## Registry slot

  The original work worker is still registered under `task_id` (parked at
  `:awaiting_review`, watched by the Watchdog). The fix-pass worker registers under
  `task_id <> ":fixpass"` so `Worker.start` doesn't collide with it — exactly the
  pattern `Arbiter.Workflows.MergeQueue.ConflictResolver` uses for `:conflict`.

  ## Merger/tracker-agnostic

  Like the `ConflictResolver`, this operates on raw git artefacts (a local
  checkout, a branch). The CI signal itself is read one layer up (by the merger
  adapter the Watchdog polls); this module only needs the failing-check briefing.

  ## Behaviour

  `FixPassDispatcher` is a behaviour so the Watchdog accepts a swappable
  implementation (defaults to this module). Tests inject a stub so they don't
  boot a real Claude session or shell out to git.
  """

  alias Arbiter.Mergers.Merger
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Worktree

  require Logger

  # This module both defines the behaviour and ships the default implementation,
  # so it implements itself.
  @behaviour __MODULE__

  # The registry suffix the fix-pass worker registers under. MUST match the
  # Watchdog's `@fix_pass_registry_suffix` so it can detect an in-flight fix pass.
  @registry_suffix ":fixpass"

  @type failing_check :: Merger.failing_check()

  @type dispatch_args :: %{
          required(:task_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:branch) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:repo_path) => String.t(),
          optional(:repo) => String.t() | nil,
          optional(:pr_ref) => term(),
          optional(:checks) => [failing_check()],
          optional(:start_claude) => boolean(),
          optional(:claude_command) => [String.t()]
        }

  @type dispatch_result ::
          {:ok, %{worker_pid: pid(), worktree_path: String.t(), branch: String.t()}}
          | {:error, term()}

  @doc """
  Spawn a worker to fix the failing checks on the task's branch and push.

  Resolves `branch`, `target_branch`, and `repo_path` from the task + workspace
  when not supplied in `args`. Returns `{:ok, info}` once the worker is spawned
  (the fix pass runs asynchronously); the Watchdog picks up the resolution on its
  next poll when CI passes and the PR turns mergeable.

  Returns `{:error, reason}` when the worker can't be spawned (no local checkout,
  no branch, a fix pass already running). The Watchdog's bounded-retry counter
  handles persistent failure by escalating after N attempts.
  """
  @callback dispatch(args :: dispatch_args()) :: dispatch_result()

  @doc """
  The registry suffix the fix-pass worker registers under (`":fixpass"`). Public
  so the Watchdog can reuse the exact same literal when checking for an in-flight
  fix pass.
  """
  @spec registry_suffix() :: String.t()
  def registry_suffix, do: @registry_suffix

  @doc """
  Default implementation of `dispatch/1`. Spawns a real Worker with a
  ClaudeSession running the fix-pass prompt inside the PR's worktree.

  Tests should pass a stub via the Watchdog's `:fix_pass_dispatcher` opt so they
  don't shell out to git or spawn `claude`.
  """
  @impl true
  @spec dispatch(dispatch_args()) :: dispatch_result()
  def dispatch(%{task_id: task_id} = args) when is_binary(task_id) do
    with {:ok, task} <- load_task(task_id),
         {:ok, context} <- resolve_context(task, args),
         {:ok, worktree_path} <- create_worktree(context),
         {:ok, worker_pid} <- start_worker(task, context, worktree_path),
         {:ok, _port} <- maybe_start_claude(worker_pid, worktree_path, context, args) do
      {:ok, %{worker_pid: worker_pid, worktree_path: worktree_path, branch: context.branch}}
    end
  end

  def dispatch(_), do: {:error, :missing_task_id}

  # ---- context resolution --------------------------------------------------

  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> {:error, {:task_not_found, task_id}}
    end
  rescue
    e -> {:error, {:task_load_failed, Exception.message(e)}}
  end

  defp resolve_context(%Issue{} = task, args) do
    workspace = maybe_load_workspace(task.workspace_id)

    branch = Map.get(args, :branch) || derive_branch(task)
    target_branch = Map.get(args, :target_branch) || workspace_base_branch(workspace) || "main"
    repo_path = Map.get(args, :repo_path) || resolve_repo_path(workspace, Map.get(args, :repo))

    cond do
      is_nil(branch) ->
        {:error, :no_branch}

      is_nil(repo_path) ->
        {:error, :no_repo_path}

      not File.dir?(repo_path) ->
        {:error, {:repo_path_missing, repo_path}}

      true ->
        {:ok,
         %{
           task: task,
           workspace: workspace,
           branch: branch,
           target_branch: target_branch,
           repo_path: repo_path,
           repo: Map.get(args, :repo) || resolve_repo_name(workspace),
           checks: Map.get(args, :checks) || []
         }}
    end
  end

  defp derive_branch(%Issue{} = task) do
    BranchNamer.derive(task)
  rescue
    _ -> nil
  end

  defp maybe_load_workspace(nil), do: nil

  defp maybe_load_workspace(ws_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp workspace_base_branch(%Workspace{config: %{} = config}) do
    case get_in(config, ["merge", "base"]) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end

  defp workspace_base_branch(_), do: nil

  # Repo path lookup mirrors `Arbiter.Workflows.MergeQueue.ConflictResolver`:
  # workspace config first, then application env, then the first configured repo.
  defp resolve_repo_path(workspace, repo) do
    workspace_repo_path(workspace, repo) || application_repo_path(repo) ||
      first_repo_path(workspace) || first_application_repo_path()
  end

  defp workspace_repo_path(_workspace, nil), do: nil

  defp workspace_repo_path(%Workspace{config: %{} = config}, repo) when is_binary(repo) do
    RepoConfig.repo_path_from_config(
      get_in(config, ["repo_paths", repo]) || get_in(config, ["rig_paths", repo])
    )
  end

  defp workspace_repo_path(_, _), do: nil

  defp first_repo_path(%Workspace{config: %{} = config}) do
    case Map.get(config, "repo_paths") || Map.get(config, "rig_paths") do
      %{} = paths -> paths |> Map.values() |> Enum.find_value(&RepoConfig.repo_path_from_config/1)
      _ -> nil
    end
  end

  defp first_repo_path(_), do: nil

  defp application_repo_path(nil), do: nil

  defp application_repo_path(repo) when is_binary(repo) do
    RepoConfig.repo_path_from_config(
      Map.get(Application.get_env(:arbiter, :repo_paths, %{}), repo)
    )
  end

  defp first_application_repo_path do
    case Application.get_env(:arbiter, :repo_paths, %{}) do
      %{} = paths -> paths |> Map.values() |> Enum.find_value(&RepoConfig.repo_path_from_config/1)
      _ -> nil
    end
  end

  defp resolve_repo_name(%Workspace{config: %{} = config}) do
    case Map.get(config, "repo_paths") || Map.get(config, "rig_paths") do
      %{} = paths -> paths |> Map.keys() |> List.first()
      _ -> nil
    end
  end

  defp resolve_repo_name(_), do: nil

  # ---- worktree / worker / claude wiring ---------------------------------

  # Attach a worktree to the (existing) PR branch — the branch already exists
  # because the PR was opened against it, so we must NOT use `Worktree.create/3`
  # (`git worktree add -b`). `Worktree.attach/2` is idempotent on the same branch.
  defp create_worktree(%{repo_path: repo_path, branch: branch}) do
    case Worktree.attach(repo_path, branch) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp start_worker(%Issue{} = task, context, worktree_path) do
    meta = %{
      role: :fix_pass,
      worktree_path: worktree_path,
      branch: nil,
      target_branch: context.target_branch,
      fix_pass_branch: context.branch,
      repo_path: context.repo_path
    }

    opts = [
      task_id: task.id,
      registry_key: task.id <> @registry_suffix,
      workspace_id: task.workspace_id,
      repo: context.repo || "unknown",
      meta: meta
    ]

    case Worker.start(opts) do
      {:ok, pid} ->
        {:ok, pid}

      # A fix pass is already in flight for this task (a previous tick's spawn
      # that hasn't terminated). Don't open a second Claude session against it.
      {:error, {:already_started, pid}} ->
        {:error, {:fix_pass_already_running, pid}}

      {:error, reason} ->
        {:error, {:worker_start_failed, reason}}
    end
  end

  # `:start_claude` defaults to `true` for production. Tests pass
  # `start_claude: false` (and a `:claude_command` argv) so they can verify the
  # dispatcher was invoked without spawning a real Claude subprocess.
  defp maybe_start_claude(worker_pid, worktree_path, context, args) do
    case Map.get(args, :start_claude, true) do
      false ->
        {:ok, nil}

      true ->
        session_opts =
          [owner: worker_pid, worktree_path: worktree_path]
          |> add_command_or_prompt(context, args)

        case ClaudeSession.start(session_opts) do
          {:ok, port} ->
            _ = Worker.advance(worker_pid, :fix_ci)
            {:ok, port}

          {:error, reason} ->
            {:error, {:claude_start_failed, reason}}
        end
    end
  end

  defp add_command_or_prompt(opts, context, args) do
    case Map.get(args, :claude_command) do
      cmd when is_list(cmd) and cmd != [] -> Keyword.put(opts, :command, cmd)
      _ -> Keyword.put(opts, :prompt, prompt_for(context))
    end
  end

  @doc """
  Fix-pass prompt. Public for tests + introspection.

  The prompt is intentionally narrow: diagnose the failing checks, fix the root
  cause, commit, push to the SAME branch, exit. It does NOT instruct the worker
  to re-implement the change set or open a new PR. It is told to escalate via the
  mailbox when the failure isn't something it can fix, rather than thrashing.
  """
  @spec prompt_for(map()) :: String.t()
  def prompt_for(%{task: %Issue{id: task_id}, branch: branch, target_branch: target} = context) do
    """
    You are a CI fix-pass worker for task #{task_id}.

    Your branch (#{branch}) has an open, approved PR against #{target}, but it
    cannot merge because its required CI checks are FAILING. Your ONLY job is to
    make those checks pass:

      1. Read the failing checks below and reproduce the failure locally where
         you can (run the failing test / linter / build).
      2. Fix the ROOT CAUSE in the code. Do not paper over a real failure by
         deleting or skipping the test unless the test itself is genuinely wrong.
      3. Commit your fix and push to the SAME branch:
         `git push origin #{branch}` (the existing PR updates in place and CI
         re-runs — do NOT open a new PR).
      4. Exit by printing `arb done` on a line by itself.

    Failing checks:
    #{render_checks(Map.get(context, :checks) || [])}

    DO NOT:
      * re-implement the change set,
      * open a new PR,
      * touch files unrelated to the failure,
      * disable or skip the check to make it "pass".

    If the failure is NOT something you can fix — an infrastructure/flake
    failure, or a failure you cannot reproduce or understand — STOP and escalate
    by running:

        arb message admiral "CI fix-pass on #{task_id} needs human review: <one-line explanation>"

    then print `arb done`. Better a loud escalation than a thrashing fix loop.
    """
  end

  def prompt_for(_) do
    "You are a CI fix-pass worker. Diagnose the failing checks, fix the root cause, push, exit."
  end

  @doc """
  Render the failing-check briefing block. Public for tests + introspection.
  """
  @spec render_checks([failing_check()]) :: String.t()
  def render_checks([]),
    do: "  (No check details were captured — inspect the PR's CI tab for the failing checks.)"

  def render_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(&render_check/1)
    |> Enum.join("\n\n")
  end

  defp render_check(%{} = check) do
    name = Map.get(check, :name) || Map.get(check, "name") || "check"
    summary = Map.get(check, :summary) || Map.get(check, "summary") || ""
    url = Map.get(check, :url) || Map.get(check, "url")

    [
      "  * #{name}" <> if(url, do: " (#{url})", else: ""),
      summary != "" && indent(summary)
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map(&("      " <> &1))
    |> Enum.join("\n")
  end
end
