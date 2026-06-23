defmodule Arbiter.Reviews.ExternalReview do
  @moduledoc """
  Review an **external / non-arbiter PR** — one the fleet never opened (a
  coworker's PR) — with no pre-linked arbiter task and no arbiter-authored
  branch (bd-d4ealy).

  ## Why this exists

  `arb review <task-id>` dispatches a claude-driven reviewer against the PR/MR
  *linked to an arbiter task* — but a task's `pr_ref` is only minted when arbiter
  itself opens/manages the MR. There was no supported path to point a review at
  an existing external PR. This module is that path: given a repo checkout + a
  PR identifier (URL or number), it constructs an `mr_ref` through the
  configured **MR-provider adapter** and runs `Arbiter.Workflows.CodeReview` in
  `:adapter` mode — read the diff, post per-finding inline comments, submit a
  single verdict — entirely against the forge, with no task / worktree / branch.

  ## Tracker vs. MR-provider split

  A workspace may track issues in Jira while its MRs live on GitHub. The review
  targets the **MR provider** (`config["merge"]["strategy"]` →
  `Arbiter.Mergers.for_workspace/1`), *not* the issue tracker. `mr_ref`
  construction is delegated to the adapter's `ref_for_pr/2` callback, so adding
  GitLab / another MR provider needs no change here — the orchestrator stays
  adapter-blind.

  ## Sync vs. async

    * `review/1` runs the whole thing synchronously and returns the verdict —
      used by tests and any caller that wants to block on the result.
    * `dispatch/1` validates synchronously (so a bad PR ref / unsupported
      strategy fails fast with a clear error) and then runs the workflow in a
      supervised background `Task`, returning a "dispatched" ack immediately.
      The findings + verdict land on the PR itself. This mirrors the
      fire-and-acknowledge semantics of `arb review`.
  """

  require Logger
  require Ash.Query

  alias Arbiter.Mergers
  alias Arbiter.Tasks.{RepoConfig, Workspace}
  alias Arbiter.Workflows.CodeReview

  @task_supervisor Arbiter.Reviews.TaskSupervisor

  @type opts :: [
          pr: String.t(),
          repo: String.t() | nil,
          workspace: String.t() | nil,
          check_runner: (String.t(), map() -> {:ok, list()} | {:error, term()}) | nil
        ]

  @doc """
  Validate an external-review request and resolve everything the workflow needs
  — workspace, MR-provider adapter, local checkout path, and the constructed
  `mr_ref` — without running the (slow) review itself.

  Fails fast on a missing/unparseable PR identifier, an unknown workspace, or a
  merge strategy with no external-PR support (e.g. `:direct`).
  """
  @spec prepare(opts() | map()) :: {:ok, map()} | {:error, term()}
  def prepare(opts) do
    opts = Map.new(opts)

    with {:ok, pr} <- fetch_pr(opts),
         {:ok, workspace} <- resolve_workspace(Map.get(opts, :workspace)),
         adapter = Mergers.for_workspace(workspace),
         strategy = Workspace.merger_strategy(workspace),
         :ok <- ensure_supports_external(adapter, strategy),
         repo_path = resolve_repo_path(workspace, Map.get(opts, :repo)),
         :ok <- Mergers.prepare(workspace),
         {:ok, mr_ref} <- adapter.ref_for_pr(pr, %{repo_path: repo_path}) do
      {:ok,
       %{
         workspace: workspace,
         adapter: adapter,
         strategy: strategy,
         mr_ref: mr_ref,
         repo_path: repo_path,
         pr: pr,
         link: safe_link(adapter, mr_ref)
       }}
    end
  end

  @doc """
  Run an external review **synchronously** and return the verdict.

  Returns `{:ok, result}` where `result` carries the `:verdict`
  (`:approve | :request_changes`), the number of `:findings`, and the resolved
  `:mr_ref` / `:link`. Returns `{:error, reason}` on a validation or workflow
  failure.
  """
  @spec review(opts() | map()) :: {:ok, map()} | {:error, term()}
  def review(opts) do
    opts = Map.new(opts)

    with {:ok, prepared} <- prepare(opts) do
      run_workflow(prepared, opts)
    end
  end

  @doc """
  Validate synchronously, then run the review in a supervised background `Task`,
  returning a "dispatched" ack immediately (`{:ok, ack}`). The findings +
  verdict are posted to the PR by the adapter when the workflow completes.

  A validation error (bad PR ref, unknown workspace, unsupported strategy)
  returns `{:error, reason}` before anything is spawned.
  """
  @spec dispatch(opts() | map()) :: {:ok, map()} | {:error, term()}
  def dispatch(opts) do
    opts = Map.new(opts)

    with {:ok, prepared} <- prepare(opts) do
      start_async(prepared, opts)
      {:ok, ack(prepared)}
    end
  end

  @doc """
  Turn any error this module returns into a single human-readable string, so the
  REST controller and the MCP tool can render a consistent message.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(:pr_required),
    do: "a PR/MR identifier is required (pass --pr <url|number>)"

  def describe_error({:unsupported_strategy, strategy}),
    do:
      "external PR review is not supported for the #{inspect(strategy)} merge strategy — " <>
        "configure a hosted MR provider (github/gitlab) under config[\"merge\"][\"strategy\"]"

  def describe_error({:workspace, msg}) when is_binary(msg), do: msg

  def describe_error(%{__struct__: mod, message: msg}) when is_binary(msg),
    do: "#{inspect(mod)}: #{msg}"

  def describe_error(other), do: "external review failed: #{inspect(other)}"

  # ---- internals -----------------------------------------------------------

  defp fetch_pr(opts) do
    case Map.get(opts, :pr) do
      pr when is_binary(pr) and pr != "" -> {:ok, String.trim(pr)}
      _ -> {:error, :pr_required}
    end
  end

  # The review targets the MR provider, so an adapter that can't mint a ref for
  # an externally-authored PR (Direct — local merge, no forge) cannot run one.
  defp ensure_supports_external(adapter, strategy) do
    # function_exported?/2 does not load the module; in interactive/mix mode the
    # adapter may not be loaded yet, so ensure it is before the export check —
    # otherwise every external review is wrongly rejected as unsupported.
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :ref_for_pr, 2) do
      :ok
    else
      {:error, {:unsupported_strategy, strategy}}
    end
  end

  defp run_workflow(prepared, opts) do
    %{adapter: adapter, mr_ref: mr_ref, workspace: workspace, repo_path: repo_path} = prepared

    state =
      %{
        mode: :adapter,
        adapter: adapter,
        mr_ref: mr_ref,
        # Threaded so CodeReview re-seeds the adapter's per-process config
        # (Mergers.prepare/1) at the start of every step — required when the
        # workflow runs in the async Task's process, not the caller's.
        workspace: workspace,
        adapter_opts: adapter_opts(repo_path)
      }
      |> maybe_put_check_runner(opts)

    case Arbiter.Workflow.run(CodeReview, state) do
      {:ok, final} -> {:ok, result(prepared, final)}
      {:error, _} = err -> err
    end
  end

  defp adapter_opts(repo_path) when is_binary(repo_path), do: %{repo_path: repo_path}
  defp adapter_opts(_), do: %{}

  # A test/advanced caller can inject a deterministic check runner; otherwise
  # CodeReview falls back to its default (a one-shot Claude review of the diff).
  defp maybe_put_check_runner(state, opts) do
    case Map.get(opts, :check_runner) do
      fun when is_function(fun, 2) -> Map.put(state, :check_runner, fun)
      _ -> state
    end
  end

  defp start_async(prepared, opts) do
    Task.Supervisor.start_child(@task_supervisor, fn ->
      case run_workflow(prepared, opts) do
        {:ok, result} ->
          Logger.info(
            "ExternalReview: #{result.strategy} #{result.mr_ref} → #{result.verdict} " <>
              "(#{result.findings} finding(s)) #{result.link}"
          )

        {:error, reason} ->
          Logger.warning(
            "ExternalReview: #{prepared.strategy} #{prepared.mr_ref} failed: #{inspect(reason)}"
          )
      end
    end)
  end

  defp ack(prepared) do
    %{
      external: true,
      status: "dispatched",
      pr: prepared.pr,
      mr_ref: prepared.mr_ref,
      strategy: prepared.strategy,
      link: prepared.link
    }
  end

  defp result(prepared, final) do
    %{
      external: true,
      pr: prepared.pr,
      mr_ref: prepared.mr_ref,
      strategy: prepared.strategy,
      link: prepared.link,
      verdict: Map.get(final, :verdict),
      findings: length(Map.get(final, :findings) || []),
      review_path: Map.get(final, :review_path)
    }
  end

  defp safe_link(adapter, mr_ref) do
    adapter.link_for(mr_ref)
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  # ---- workspace resolution ------------------------------------------------
  #
  # nil → the installation default (the lone workspace, else the one named
  # "default"); a string → a workspace id, then a workspace name. Mirrors the
  # resolution `Arbiter.MCP.Tools` uses for workspace-agnostic coordinator tools.

  defp resolve_workspace(nil), do: default_workspace()

  defp resolve_workspace(ref) when is_binary(ref) and ref != "" do
    with :error <- workspace_by_id(ref),
         :error <- workspace_by_name(ref) do
      {:error, {:workspace, "workspace #{inspect(ref)} not found"}}
    end
  end

  defp resolve_workspace(_), do: default_workspace()

  defp default_workspace do
    case Ash.read!(Workspace) do
      [%Workspace{} = ws] ->
        {:ok, ws}

      [] ->
        {:error, {:workspace, "no workspaces exist on this installation"}}

      many ->
        case Enum.find(many, &(&1.name == "default")) do
          %Workspace{} = ws -> {:ok, ws}
          nil -> {:error, {:workspace, "multiple workspaces; pass a workspace name or id"}}
        end
    end
  rescue
    e -> {:error, {:workspace, "could not load workspaces: #{Exception.message(e)}"}}
  end

  defp workspace_by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp workspace_by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ---- repo path resolution ------------------------------------------------
  #
  # Map a repo name to its local checkout via the workspace `repo_paths` (legacy
  # `rig_paths`) config, falling back to the global `:arbiter, :repo_paths` app
  # env — the same lookup order `Arbiter.Worker.Dispatch` uses. nil when no repo
  # was named or it isn't mapped (a bare PR number then can't derive owner/repo
  # and a full PR URL is required).

  defp resolve_repo_path(_workspace, nil), do: nil
  defp resolve_repo_path(_workspace, ""), do: nil

  defp resolve_repo_path(%Workspace{config: config}, repo) when is_binary(repo) do
    from_config =
      RepoConfig.repo_path_from_config(
        get_in(config || %{}, ["repo_paths", repo]) || get_in(config || %{}, ["rig_paths", repo])
      )

    from_config || application_repo_path(repo)
  end

  defp application_repo_path(repo) do
    :arbiter
    |> Application.get_env(:repo_paths, %{})
    |> Map.get(repo)
    |> RepoConfig.repo_path_from_config()
  end
end
