defmodule Arbiter.Workflows.MergeQueue.ConflictResolver do
  @moduledoc """
  Spawn a short-lived worker to rebase a CONFLICTING bead branch onto the
  current head of its target branch, resolve conflicts, and force-push.

  Invoked by `Arbiter.Workflows.MergeQueue` when a merge queue item enters the
  CONFLICTING state (the merger reports `mergeable: false` on the PR).
  Before this, the queue froze the item and waited for a human to rebase —
  twice this morning that meant an Admiral page on a dispatcher-bead
  collision (#117, #121). The resolver worker exists so that case unblocks
  itself.

  ## Job scope

  The worker is given a *narrowly* constrained prompt: rebase onto the
  current target branch, resolve mechanical conflicts, push back with
  `--force-with-lease`, and exit. It must NOT re-implement the change set
  or open a new PR. The original PR's history is preserved (force-push to
  the same branch updates the existing PR in place).

  When the conflict is mechanical (parallel edits to non-overlapping
  sections of a structured map like the dispatcher `@known_verbs` /
  command-alias tables) the rebase resolves itself with no semantic
  judgement needed. When the conflict is semantic — two waves both
  rewrote the same predicate or both changed a shared invariant — the
  worker escalates via the workspace mailbox (an `:escalation` to
  `to_ref: "admiral"`) rather than silently failing.

  ## Merger/tracker-agnostic

  This module operates on raw git artefacts (a local checkout, a branch
  name, a target branch). It is unaware of GitHub/GitLab/etc — those live
  one layer up in the MergeQueue, which detects the CONFLICTING state from
  whichever forge adapter it's wired to. A future merge queue variant that
  speaks GitLab MRs reuses this resolver unchanged.

  ## Behaviour

  `ConflictResolver` is a behaviour so the MergeQueue accepts a swappable
  resolver implementation (defaults to this module). Tests inject a
  noop stub so they do not boot a real Claude session or shell out to
  git.
  """

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.RepoConfig
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.BranchNamer
  alias Arbiter.Polecat.ClaudeSession
  alias Arbiter.Polecat.Worktree

  require Logger

  # This module both defines the behaviour and ships the default
  # implementation, so it implements itself. The `@impl true` annotations
  # on resolve/1, escalate_unresolved/4, and notify_resolution/3 require this.
  @behaviour __MODULE__

  @type resolve_args :: %{
          required(:bead_id) => String.t(),
          required(:workspace_id) => String.t() | nil,
          optional(:branch) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:repo_path) => String.t(),
          optional(:repo) => String.t() | nil,
          optional(:pr_ref) => term(),
          optional(:start_claude) => boolean(),
          optional(:claude_command) => [String.t()]
        }

  @type resolve_result ::
          {:ok, %{polecat_pid: pid(), worktree_path: String.t(), branch: String.t()}}
          | {:error, term()}

  @doc """
  Spawn a worker to rebase + resolve + push the bead's branch.

  Resolves `branch`, `target_branch`, and `repo_path` from the bead +
  workspace when not supplied in `args`. Returns `{:ok, info}` once the
  worker is spawned (the rebase runs asynchronously); the MergeQueue picks
  up the resolution on its next poll when the PR turns mergeable again.

  When the worker cannot be spawned (no local checkout, no branch,
  workspace missing) returns `{:error, reason}`. The MergeQueue's escalation
  path handles that by mailing the Admiral so the bead does not sit in
  CONFLICTING limbo.
  """
  @callback resolve(args :: resolve_args()) :: resolve_result()

  @doc """
  Optional: post an `:escalation` mailbox message to the Admiral about an
  unresolved conflict. The MergeQueue calls this on spawn failure and on the
  second consecutive CONFLICTING observation. The real
  `Arbiter.Workflows.MergeQueue.ConflictResolver` implements it; test stubs
  may implement it to intercept escalations for assertion.
  """
  @callback escalate_unresolved(
              bead_id :: String.t(),
              workspace_id :: String.t() | nil,
              branch :: String.t(),
              reason :: term()
            ) :: :ok

  @doc """
  Optional: post a `:notification` announcing a successful auto-resolution.
  The MergeQueue calls this when a CONFLICTING PR turns mergeable again on
  a poll. The real `Arbiter.Workflows.MergeQueue.ConflictResolver` implements
  it; test stubs may implement it to intercept notifications for assertion.
  """
  @callback notify_resolution(
              bead_id :: String.t(),
              workspace_id :: String.t() | nil,
              branch :: String.t()
            ) :: :ok

  @optional_callbacks escalate_unresolved: 4, notify_resolution: 3

  @doc """
  Default implementation of `resolve/1`. Spawns a real Polecat with a
  ClaudeSession running the resolver prompt inside a fresh worktree.

  Tests should pass a stub module via the MergeQueue's `:conflict_resolver`
  opt so they don't shell out to git or spawn `claude`.
  """
  @impl true
  @spec resolve(resolve_args()) :: resolve_result()
  def resolve(%{bead_id: bead_id} = args) when is_binary(bead_id) do
    with {:ok, bead} <- load_bead(bead_id),
         {:ok, context} <- resolve_context(bead, args),
         {:ok, worktree_path} <- create_worktree(context),
         {:ok, polecat_pid} <- start_polecat(bead, context, worktree_path),
         {:ok, _port} <- maybe_start_claude(polecat_pid, worktree_path, context, args) do
      {:ok,
       %{
         polecat_pid: polecat_pid,
         worktree_path: worktree_path,
         branch: context.branch
       }}
    end
  end

  def resolve(_), do: {:error, :missing_bead_id}

  # ---- context resolution --------------------------------------------------

  defp load_bead(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, bead} -> {:ok, bead}
      {:error, _} -> {:error, {:bead_not_found, bead_id}}
    end
  rescue
    e -> {:error, {:bead_load_failed, Exception.message(e)}}
  end

  # Resolve everything the worker needs: a local checkout to cut the worktree
  # from, the bead's branch name, and the target branch to rebase onto. Caller-
  # supplied args win over derived values so the MergeQueue and tests can override.
  defp resolve_context(%Issue{} = bead, args) do
    workspace = maybe_load_workspace(bead.workspace_id)

    branch = Map.get(args, :branch) || derive_branch(bead)
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
           bead: bead,
           workspace: workspace,
           branch: branch,
           target_branch: target_branch,
           repo_path: repo_path,
           repo: Map.get(args, :repo) || resolve_repo_name(workspace)
         }}
    end
  end

  defp derive_branch(%Issue{} = bead) do
    BranchNamer.derive(bead)
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

  # Repo path lookup mirrors `Arbiter.Polecat.Dispatch`: workspace config first,
  # then application env. Without an explicit repo we take the first configured
  # repo path — the canonical "one repo per workspace" path covers every existing
  # merge queue target.
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
    paths =
      Map.get(config, "repo_paths") || Map.get(config, "rig_paths")

    case paths do
      %{} ->
        paths
        |> Map.values()
        |> Enum.find_value(&RepoConfig.repo_path_from_config/1)

      _ ->
        nil
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
      %{} = paths ->
        paths
        |> Map.values()
        |> Enum.find_value(&RepoConfig.repo_path_from_config/1)

      _ ->
        nil
    end
  end

  defp resolve_repo_name(%Workspace{config: %{} = config}) do
    paths = Map.get(config, "repo_paths") || Map.get(config, "rig_paths")

    case paths do
      %{} -> paths |> Map.keys() |> List.first()
      _ -> nil
    end
  end

  defp resolve_repo_name(_), do: nil

  # ---- worktree / polecat / claude wiring ---------------------------------

  # Registry suffix the conflict-resolver polecat registers under. The original
  # work polecat is still registered (and sitting `:completed`) when the
  # merge queue picks up the CONFLICTING signal — the registry key is keyed on
  # bead_id and the original is only torn down on bead `:close`. Spawning under
  # `<bead_id>:conflict` gives the resolver its own slot so `Polecat.start`
  # doesn't return `:already_started` and we don't accidentally open a Claude
  # session against the finished polecat.
  @resolver_registry_suffix ":conflict"

  # Attach a worktree to the (existing) PR branch — the branch already exists
  # in the repo because the conflicting PR was opened against it, so we must
  # NOT use `Worktree.create/3` (that runs `git worktree add -b <branch> …`,
  # which fails when the branch already exists). `Worktree.attach/2` runs
  # `git worktree add <path> <existing-branch>` and is idempotent on the
  # same-branch path. The resolver worker then fetches the latest target
  # branch and rebases onto it from that worktree.
  defp create_worktree(%{repo_path: repo_path, branch: branch}) do
    case Worktree.attach(repo_path, branch) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp start_polecat(%Issue{} = bead, context, worktree_path) do
    meta = %{
      role: :conflict_resolver,
      worktree_path: worktree_path,
      branch: nil,
      target_branch: context.target_branch,
      conflict_resolver_branch: context.branch,
      repo_path: context.repo_path
    }

    opts = [
      bead_id: bead.id,
      registry_key: bead.id <> @resolver_registry_suffix,
      workspace_id: bead.workspace_id,
      repo: context.repo || "unknown",
      meta: meta
    ]

    case Polecat.start(opts) do
      {:ok, pid} ->
        {:ok, pid}

      # A resolver is already in flight for this bead (a previous tick's
      # spawn that hasn't terminated yet). Don't open a second Claude session
      # against it — surface the collision so the MergeQueue's escalation path
      # mails the Admiral instead of pretending we restarted the rebase.
      {:error, {:already_started, pid}} ->
        {:error, {:resolver_already_running, pid}}

      {:error, reason} ->
        {:error, {:polecat_start_failed, reason}}
    end
  end

  # `:start_claude` defaults to `true` for production. Tests pass
  # `start_claude: false` (and a `:claude_command` argv) so they can verify
  # the resolver was invoked without spawning a real Claude subprocess.
  defp maybe_start_claude(polecat_pid, worktree_path, context, args) do
    case Map.get(args, :start_claude, true) do
      false ->
        {:ok, nil}

      true ->
        session_opts =
          [
            owner: polecat_pid,
            worktree_path: worktree_path
          ]
          |> add_command_or_prompt(context, args)

        case ClaudeSession.start(session_opts) do
          {:ok, port} ->
            _ = Polecat.advance(polecat_pid, :resolve_conflict)
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
  Resolver prompt. Public for tests + introspection.

  The prompt is intentionally narrow: rebase + resolve + force-push + exit.
  It does NOT instruct the worker to re-implement the change set or open a
  new PR — the original PR's history is preserved by force-pushing to the
  same branch. The worker is told to escalate via the mailbox on semantic
  ambiguity rather than failing silently.
  """
  @spec prompt_for(map()) :: String.t()
  def prompt_for(%{bead: %Issue{id: bead_id}, branch: branch, target_branch: target}) do
    """
    You are a conflict-resolution worker for bead #{bead_id}.

    Your branch (#{branch}) is CONFLICTING with the current head of
    #{target}. Your ONLY job is:

      1. Fetch the latest #{target}: `git fetch origin #{target}`
      2. Rebase your branch onto it: `git rebase origin/#{target}`
      3. Resolve conflicts mechanically. Most collisions on this codebase
         are parallel edits to non-overlapping sections of structured
         tables (the dispatcher `@known_verbs` and the command-alias
         resolver). For those, accept BOTH sides of the conflict and
         continue: `git rebase --continue`.
      4. Push back with lease: `git push --force-with-lease origin #{branch}`
      5. Exit by printing `arb done` on a line by itself.

    DO NOT:
      * re-implement the change set,
      * open a new PR,
      * touch files unrelated to the conflict,
      * abandon the rebase silently.

    If a conflict is SEMANTIC — two waves both rewrote the same predicate
    or both changed a shared invariant where a mechanical merge would
    silently break either side — STOP and escalate by running:

        arb message admiral "Conflict on #{bead_id} requires human review: <one-line explanation>"

    then print `arb done`. Better a loud escalation than a silent
    miscompile in #{target}.
    """
  end

  def prompt_for(_) do
    "You are a conflict-resolution worker. Rebase, resolve, force-push, exit."
  end

  # ---- escalation helper ---------------------------------------------------

  @doc """
  Post an `:escalation` mailbox message to the Admiral about an unresolved
  conflict. Used by the MergeQueue when the resolver itself can't be spawned
  or the second consecutive CONFLICTING observation arrives (the rebase
  pass didn't unblock the PR).

  Best-effort: a DB hiccup is logged but never re-raised so the caller's
  state machine isn't disrupted.
  """
  @impl true
  @spec escalate_unresolved(String.t(), String.t() | nil, String.t(), term()) :: :ok
  def escalate_unresolved(bead_id, workspace_id, branch, reason)
      when is_binary(bead_id) and is_binary(workspace_id) do
    body =
      """
      The merge queue detected a CONFLICTING PR for bead #{bead_id} (branch
      #{branch}) and could not auto-resolve it (#{inspect_short(reason)}).
      Manual rebase + push required before the merge queue can proceed.
      """

    Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: bead_id,
      workspace_id: workspace_id,
      directive_ref: bead_id,
      subject: "Merge queue: unresolved conflict on #{bead_id}",
      body: body
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "ConflictResolver.escalate_unresolved swallowed for bead=#{bead_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  def escalate_unresolved(_bead_id, _workspace_id, _branch, _reason), do: :ok

  @doc """
  Post a `:notification` announcing a successful auto-resolution. Used by
  the MergeQueue when the next poll after a resolver spawn shows the PR is
  mergeable again — the rebase + force-push worked.

  Symmetric with `escalate_unresolved/4` so the acceptance criterion
  ("notified of the resolution OR the escalation") is satisfied on both
  sides. Best-effort: DB hiccups are logged but never re-raised.
  """
  @impl true
  @spec notify_resolution(String.t(), String.t() | nil, String.t()) :: :ok
  def notify_resolution(bead_id, workspace_id, branch)
      when is_binary(bead_id) and is_binary(workspace_id) do
    body =
      """
      The merge queue auto-resolved a CONFLICTING PR for bead #{bead_id}
      (branch #{branch}) — the conflict-resolver worker rebased onto the
      current target branch, resolved the conflict, and force-pushed. The
      merge queue is resuming.
      """

    Message.notify(%{
      from_ref: bead_id,
      workspace_id: workspace_id,
      subject: "Merge queue: auto-resolved conflict on #{bead_id}",
      body: body
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "ConflictResolver.notify_resolution swallowed for bead=#{bead_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  def notify_resolution(_bead_id, _workspace_id, _branch), do: :ok

  defp inspect_short(reason) when is_binary(reason), do: reason
  defp inspect_short(reason), do: reason |> inspect() |> String.slice(0, 200)
end
