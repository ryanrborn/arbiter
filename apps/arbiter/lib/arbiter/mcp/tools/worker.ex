defmodule Arbiter.MCP.Tools.Worker do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the worker lifecycle: `worker_dispatch` /
  `worker_resume` / `worker_review` / `worker_stop` / `worker_list` /
  `worker_show` / `worker_runs` / `worker_log` / `worker_prompt` /
  `run_log_list` / `transcript_capture_stats`. Split out of
  `Arbiter.MCP.Tools` (see its moduledoc) — called back into for the generic
  arg/serialization helpers, `ensure_can_dispatch/1`, and `parse_bounded_limit/4`
  it still owns (the latter two are shared with `review_greenlight` /
  `external_review_list`, which stayed in `Arbiter.MCP.Tools`).
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Trackers
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Worker.ReviewGate

  require Ash.Query
  require Logger

  @corpus_start_date ~U[2026-06-20 00:00:00Z]

  # ---- worker_dispatch ------------------------------------------------------

  @doc """
  Dispatch a worker to work a task in the scope's workspace. **Coordinator only,
  and the strongest-gated tool.** It enforces the dispatch-recursion guardrail
  (`docs/mcp-server-design.md` §4.3):

    1. The scope must carry `can_dispatch` — a coordinator minted without it (and
       every worker, which never carries it) is refused.
    2. The scope's `depth` must be below the configured `Arbiter.MCP.max_depth/0`
       — cheap insurance against a misconfigured coordinator fan-out.

  The slung worker's own scope token is minted one level deeper (`depth + 1`),
  so a chain of dispatches is tracked. When `provider` is omitted, the workspace's
  `agent.type` config is consulted and the first healthy provider is selected via
  `ProviderPool` — identical to the REST dispatch default. Pass an explicit
  `provider` (`"claude"` | `"gemini"`, or the deprecated `with_claude: true` alias)
  to override. Set `no_agent: true` to park the task `:in_progress` without
  spawning a worker (hand-off / manual-attach path).
  Backs onto `Arbiter.Worker.Dispatch.dispatch/2`.
  """
  @spec worker_dispatch(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_dispatch(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, opts} <- worker_dispatch_opts(scope, args) do
      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason, task_id)}}
      end
    end
  end

  # ---- worker_resume -----------------------------------------------------

  @doc """
  Re-attach a fresh worker to a task's **preserved** worktree
  (`arb resume`). Coordinator only, and — like `worker_dispatch` — gated by the
  dispatch-recursion guardrail (`can_dispatch` + `depth`): resume spawns a worker, so
  the same recursion concerns apply. The child worker's scope is minted one
  level deeper. Backs onto `Arbiter.Worker.Dispatch.resume/2`.
  """
  @spec worker_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_resume(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      case Dispatch.resume(task_id, dispatch_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason, task_id)}}
      end
    end
  end

  # ---- worker_review -----------------------------------------------------

  @doc """
  Dispatch a **review-only** worker (`arb review`): no worktree, no per-task
  branch, no route through the merge queue/merger. Coordinator only, and gated
  by the dispatch-recursion guardrail (`can_dispatch` + `depth`) — a review
  spawns an agent.

  Two shapes:

    * `task_id` → review the PR/MR linked to a task. Backs onto
      `Arbiter.Worker.Dispatch.dispatch/2` with `review: true`; the child
      worker's scope is minted one level deeper.
    * `pr` (URL or number, + optional `repo`/`workspace`) → review an
      **external / non-arbiter PR** through the MR adapter
      (`Arbiter.Reviews.ExternalReview`): no task, no branch. Findings + a
      verdict are posted to the PR.
  """
  @spec worker_review(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_review(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "pr") do
      pr when is_binary(pr) -> worker_review_external(scope, args, pr)
      _ -> worker_review_task(scope, args)
    end
  end

  defp worker_review_task(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, task} <- maybe_set_tracker_context(task, args),
         {:ok, force} <- Tools.fetch_bool(args, "force", false),
         {:ok, mode} <- guard_review_automation(scope, args, force),
         {:ok, _} <- persist_review_automation(task, mode) do
      opts =
        scope
        |> dispatch_opts(args)
        |> Keyword.put(:review, true)
        |> review_claude_flag(args)

      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason, task_id)}}
      end
    end
  end

  # Resolve the review_automation mode (+ its source, logged for visibility —
  # bd-7opdaf) and refuse the dispatch outright when it resolves to `:off`,
  # UNLESS `force: true` is passed — mirrors the external (`pr:`) path's
  # `guard_automation_off/2` in `Arbiter.Reviews.ExternalReview`. No task is
  # touched and no worker is spawned when this refuses.
  #
  # Resolution order (most-specific wins):
  #   1. An explicit `automation` arg passed to `worker_review` — hard override.
  #   2. The workspace's `review_automation.repo_overrides[repo]` — per-repo hard gate.
  #   3. The workspace's `review_automation.auto_authors` list, then `default`.
  #   4. No config → :flag (conservative: never auto-post unless explicitly trusted).
  defp guard_review_automation(scope, args, force) do
    pr_author = Tools.fetch_string(args, "pr_author")
    repo_name = Tools.fetch_string(args, "repo")
    ws_config = load_workspace_config(scope.workspace_id)
    explicit = Tools.fetch_string(args, "automation")

    {mode, source} =
      ReviewAutomation.resolve_with_source(ws_config, pr_author, repo_name, explicit)

    Logger.info(
      "worker_review(task_id): resolved review_automation=#{mode} (source: #{source})" <>
        if(repo_name, do: " [#{repo_name}]", else: "")
    )

    cond do
      mode != :off -> {:ok, mode}
      force -> {:ok, mode}
      true -> {:error, {:invalid, automation_off_message(repo_name, source)}}
    end
  end

  defp automation_off_message(repo_name, :repo_override) when is_binary(repo_name) do
    "review_automation is \"off\" for #{repo_name} " <>
      "(review_automation.repo_overrides[#{inspect(repo_name)}]); refusing to dispatch a " <>
      "reviewer — pass force: true to override"
  end

  defp automation_off_message(repo_name, :explicit) do
    "review_automation was explicitly set to \"off\" for #{repo_name || "this task"} " <>
      "(the automation argument); refusing to dispatch a reviewer — pass force: true to override"
  end

  defp automation_off_message(repo_name, :default) when is_binary(repo_name) do
    "review_automation is \"off\" by default for #{repo_name} (review_automation.default); " <>
      "refusing to dispatch a reviewer — pass force: true to override"
  end

  defp automation_off_message(_repo_name, :default) do
    "review_automation is \"off\" by default for this workspace (review_automation.default); " <>
      "refusing to dispatch a reviewer — pass force: true to override"
  end

  # Persist the (already-guarded) review_automation mode on the engagement
  # task, so the ReviewPatrol poller can read it from the task without
  # re-loading workspace config on each cycle.
  defp persist_review_automation(task, mode) do
    case Ash.update(task, %{review_automation: mode}) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
    end
  end

  defp load_workspace_config(nil), do: nil

  defp load_workspace_config(ws_id) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, %{config: config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # If `tracker_context_ref` is provided in args, persist it (and optionally
  # `tracker_context_type`) on the task before dispatch so the review prompt
  # can fetch the ticket's acceptance criteria. When `tracker_context_type` is
  # omitted, the workspace's default tracker type is used as the fallback —
  # the most common case (reviewee and reviewer share the same tracker).
  defp maybe_set_tracker_context(task, args) do
    case Tools.fetch_string(args, "tracker_context_ref") do
      ref when is_binary(ref) and ref != "" ->
        context_type =
          case Tools.fetch_string(args, "tracker_context_type") do
            t when is_binary(t) and t != "" ->
              try do
                String.to_existing_atom(t)
              rescue
                ArgumentError -> nil
              end

            _ ->
              case Tools.fetch_workspace(task.workspace_id) do
                {:ok, ws} -> Trackers.workspace_type(ws)
                _ -> nil
              end
          end

        attrs =
          %{"tracker_context_ref" => ref}
          |> then(fn m ->
            if context_type, do: Map.put(m, "tracker_context_type", context_type), else: m
          end)

        case Ash.update(task, attrs, action: :update) do
          {:ok, updated} -> {:ok, updated}
          {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
        end

      _ ->
        {:ok, task}
    end
  end

  # External PR review: same dispatch gating (it spawns a reviewer), but resolves
  # the MR provider from the (scope-bound or named) workspace rather than a task.
  #
  # `follow_up` (Option A, bd-2ovun1) makes the review adopt the PR into
  # ReviewPatrol by opening a review_only engagement after the verdict posts.
  # When the arg is omitted, ExternalReview engages by default only if the
  # workspace has a ReviewPatrol running. `automation` / `tracker_context_*`
  # mirror the task-review path and are carried onto that engagement.
  defp worker_review_external(%Scope{} = scope, args, pr) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, ws_ref} <- Tools.authorized_workspace(scope, args),
         {:ok, follow_up} <- Tools.fetch_optional_bool(args, "follow_up"),
         {:ok, force} <- Tools.fetch_optional_bool(args, "force") do
      opts =
        [
          pr: pr,
          repo: Tools.fetch_string(args, "repo"),
          workspace: ws_ref,
          automation: Tools.fetch_string(args, "automation"),
          tracker_context_ref: Tools.fetch_string(args, "tracker_context_ref"),
          tracker_context_type: Tools.fetch_string(args, "tracker_context_type"),
          dispatched_by: "mcp"
        ]
        |> Tools.maybe_put_kw(:follow_up, follow_up)
        |> Tools.maybe_put_kw(:force, force)
        |> Tools.maybe_put_kw(:scope, Tools.fetch_string(args, "scope"))

      case Arbiter.Reviews.ExternalReview.dispatch(opts) do
        {:ok, ack} ->
          {:ok, ack}

        {:error, reason} ->
          {:error, {:invalid, Arbiter.Reviews.ExternalReview.describe_error(reason)}}
      end
    end
  end

  # ---- worker_stop -------------------------------------------------------

  @doc """
  Stop the worker currently working a task (`arb worker stop`). Coordinator
  only. The task is resolved through `fetch_task`, so a coordinator can only
  stop workers for tasks in its own workspace; a task with no live worker is
  reported as not-found. Stopping is teardown — it never spawns — so it does not
  require `can_dispatch`. Backs onto `Arbiter.Worker.stop/2`.
  """
  @spec worker_stop(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_stop(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      case Worker.stop(task_id, :normal) do
        :ok -> {:ok, %{task_id: task_id, stopped: true}}
        {:error, :not_found} -> {:error, {:not_found, "no running worker for task #{task_id}"}}
      end
    end
  end

  # ---- worker_list -------------------------------------------------------

  @doc """
  List active workers in the scope's workspace. Coordinator only. Backs onto
  `Arbiter.Worker.list_children/0`, filtered to the scope's workspace_id so a
  coordinator never sees workers running in other workspaces.
  """
  @spec worker_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      children =
        Arbiter.Worker.list_children()
        |> Enum.filter(&(&1.workspace_id == ws_id))

      task_ids = Enum.map(children, & &1.task_id)
      costs = Arbiter.Worker.Stats.task_costs_usd(task_ids)

      workers =
        Enum.map(children, &serialize_worker_summary(&1, Map.get(costs, &1.task_id, 0.0)))

      {:ok, %{workers: workers, count: length(workers)}}
    end
  end

  # ---- worker_show --------------------------------------------------------

  @doc """
  Full snapshot for a single task's worker (`arb worker show <task-id>`).
  When a worker is currently live, returns its in-memory state (status,
  activity, recent output lines, etc). Otherwise falls back to the most
  recent durable `Arbiter.Workers.Run` row so a finished/exited run stays
  inspectable. Not-found only when neither a live worker nor any run has
  ever been recorded for the task.
  """
  @spec worker_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_show(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, lines} <- Tools.optional_integer(args, "lines"),
         {:ok, lines} <- validate_positive_integer(lines, "lines") do
      case Worker.whereis(task_id) do
        nil ->
          worker_show_historical(task_id, lines)

        pid ->
          case Worker.state(pid) do
            %{} = snap -> {:ok, serialize_worker_snapshot(Map.put(snap, :pid, pid), lines)}
            _ -> worker_show_historical(task_id, lines)
          end
      end
    end
  end

  defp worker_show_historical(task_id, lines) do
    case latest_run(task_id) do
      %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_run(run, lines)}
      nil -> {:error, {:not_found, "no worker found for task #{task_id}"}}
    end
  end

  defp latest_run(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # ---- worker_runs ----------------------------------------------------------

  @doc """
  List every historical `Arbiter.Workers.Run` recorded for a task, newest
  first (`arb worker runs <task-id>`). Mirrors `GET /api/workers/history?task_id=`:
  each entry is a run summary (no `output_lines` — fetch a single run's full
  output via `worker_log` for the transcript). Optional `limit` (default 20,
  max 200).

  `task_id` may be a synthetic ReviewGate id (`<base>#review`, `#r<N>`,
  `#impl<N>`, `#v<N>`, `#t<N>`) — those are not `issues` rows, so the
  authorization check resolves to the base task while the run lookup keeps
  the full synthetic id, surfacing the reviewer/re-prompt corpus.
  """
  @spec worker_runs(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_runs(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)),
         {:ok, limit} <- Tools.parse_bounded_limit(args, "limit", 20, 200) do
      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(task_id == ^task_id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, %{runs: Enum.map(runs, &serialize_worker_run_summary/1)}}
    end
  end

  # ---- worker_log ------------------------------------------------------------

  @doc """
  Full, uncapped durable transcript of one run — the audit source of record,
  retaining every line however long the run. Two ways to select the run:

    * `run_id:` — that exact run, independent of which run is latest for its
      task. This is the only way to reach a superseded/failed attempt once a
      later run exists for the same task.
    * `task_id:` (no `run_id`) — the task's most recent run (`arb worker log
      <task-id>`), unchanged from prior behaviour. `task_id` may be a
      synthetic ReviewGate id (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`,
      `#t<N>`); the authorization check resolves it to the base task while
      the run lookup keeps the full synthetic id.

  `exists` distinguishes "no file yet / never captured" (false, empty
  `lines`) from "captured but empty" (true, empty `lines`). Not-found when no
  matching run exists (or, for `run_id`, when it belongs to another workspace).
  """
  @spec worker_log(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_log(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "run_id") do
      nil -> worker_log_by_task(scope, args)
      run_id -> worker_log_by_run_id(scope, args, run_id)
    end
  end

  defp worker_log_by_task(scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)) do
      case latest_run(task_id) do
        %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_log(run)}
        nil -> {:error, {:not_found, "no worker run found for task #{task_id}"}}
      end
    end
  end

  defp worker_log_by_run_id(scope, args, run_id) do
    with {:ok, run} <- fetch_run(scope, args, run_id) do
      {:ok, serialize_worker_log(run)}
    end
  end

  defp serialize_worker_log(%Arbiter.Workers.Run{} = run) do
    {exists, lines} =
      case Arbiter.Worker.OutputLog.read_lines(run.id) do
        {:ok, lines} -> {true, lines}
        {:error, _} -> {false, []}
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: Arbiter.Worker.OutputLog.path_for(run.id),
      exists: exists,
      line_count: length(lines),
      lines: lines
    }
  end

  # Fetch a single `Arbiter.Workers.Run` by id, enforcing workspace isolation
  # the same way `fetch_task/3` does for `issues` rows. Not-found (rather than
  # unauthorized) on a cross-workspace hit so existence doesn't leak.
  defp fetch_run(scope, args, run_id) do
    with {:ok, target_ws} <- Tools.authorized_workspace(scope, args) do
      case Ash.get(Arbiter.Workers.Run, run_id) do
        {:ok, %Arbiter.Workers.Run{} = run} ->
          if Tools.workspace_match?(run.workspace_id, target_ws),
            do: {:ok, run},
            else: {:error, {:not_found, "run #{run_id} not found"}}

        _ ->
          {:error, {:not_found, "run #{run_id} not found"}}
      end
    end
  end

  defp serialize_worker_run_summary(%Arbiter.Workers.Run{} = run) do
    %{
      id: run.id,
      task_id: run.task_id,
      task_title: run.task_title,
      repo: run.repo,
      workspace_id: run.workspace_id,
      worker_type: Tools.to_str(run.worker_type),
      status: Tools.to_str(run.status),
      model: run.model,
      started_at: Tools.iso(run.started_at),
      completed_at: Tools.iso(run.completed_at),
      exit_code: run.exit_code,
      failure_reason: run.failure_reason,
      resolved_skills: run.resolved_skills || [],
      standing_orders_digest: run.standing_orders_digest,
      routing_policy: run.routing_policy,
      model_tier: run.model_tier,
      thinking: run.thinking,
      difficulty_at_dispatch: run.difficulty_at_dispatch
    }
  end

  # ---- worker_prompt ----------------------------------------------------

  @doc """
  The composed prompt one run was spawned with (bd-9rdwe4, #1017 gap G5),
  redacted through the same choke-point as transcript lines. Sibling of
  `worker_log/2` — same `run_id`/`task_id` selection rule, same
  synthetic-id-aware task resolution.

  `exists` distinguishes "no prompt was ever persisted for this run" (false,
  `prompt` nil) from a captured one — including a run whose prompt redacted
  down to something shorter than what was typed, which is still "exists".
  """
  @spec worker_prompt(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_prompt(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "run_id") do
      nil -> worker_prompt_by_task(scope, args)
      run_id -> worker_prompt_by_run_id(scope, args, run_id)
    end
  end

  defp worker_prompt_by_task(scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)) do
      case latest_run(task_id) do
        %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_prompt(run)}
        nil -> {:error, {:not_found, "no worker run found for task #{task_id}"}}
      end
    end
  end

  defp worker_prompt_by_run_id(scope, args, run_id) do
    with {:ok, run} <- fetch_run(scope, args, run_id) do
      {:ok, serialize_worker_prompt(run)}
    end
  end

  defp serialize_worker_prompt(%Arbiter.Workers.Run{} = run) do
    {exists, prompt} =
      case Arbiter.Worker.PromptLog.read(run.id) do
        {:ok, content} -> {true, content}
        {:error, _} -> {false, nil}
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: Arbiter.Worker.PromptLog.path_for(run.id),
      exists: exists,
      prompt: prompt,
      prompt_sha256: run.prompt_sha256
    }
  end

  # ---- run_log_list -----------------------------------------------------

  @doc """
  Enumerate every run recorded for a task **and its ReviewGate synthetic
  children** (`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`),
  newest first — the whole retrievable transcript corpus for a task in one
  call. Unlike `worker_runs` (exact `task_id` match only), this matches the
  task id itself plus anything prefixed `<task_id>#`, so a single call
  surfaces the reviewer/re-prompt corpus alongside the author's own runs.

  Each entry reports `transcript_exists` so a missing durable log is
  distinguishable from an empty one without a separate `worker_log` call.
  `task_id` must be the base task (a plain `issues` id) — pass it
  un-suffixed even to reach synthetic runs.
  """
  @spec run_log_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def run_log_list(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)),
         {:ok, limit} <- Tools.parse_bounded_limit(args, "limit", 200, 1000) do
      prefix = task_id <> "#"

      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(task_id == ^task_id or string_starts_with(task_id, ^prefix))
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, %{runs: Enum.map(runs, &serialize_run_log_entry/1)}}
    end
  end

  defp serialize_run_log_entry(%Arbiter.Workers.Run{} = run) do
    %{
      run_id: run.id,
      task_id: run.task_id,
      worker_type: Tools.to_str(run.worker_type),
      status: Tools.to_str(run.status),
      model: run.model,
      started_at: Tools.iso(run.started_at),
      transcript_exists: File.regular?(Arbiter.Worker.OutputLog.path_for(run.id)),
      line_count: run.id |> Arbiter.Worker.OutputLog.read_lines() |> line_count_of()
    }
  end

  defp line_count_of({:ok, lines}), do: length(lines)
  defp line_count_of({:error, _}), do: 0

  # ---- transcript_capture_stats -------------------------------------------

  # 2026-06-19 rename (commit 8181cfc) moved the durable-transcript root from
  # the retired `arbiter-polecat-logs` to `arbiter-worker-logs`; `path_for/1`
  # only ever looks in the current root. That's an accepted loss (bd-9wotbo,
  # operator decision 2026-07-28) — no migration, no legacy-root fallback — so
  # every run before this date is definitionally unreachable and must be
  # excluded from the denominator rather than counted as a capture failure.

  @doc """
  Transcript-capture health for a workspace (bd-9wotbo, gap G4): what fraction
  of Claude-driven runs actually produced a durable transcript, scoped to
  `started_at >= #{@corpus_start_date}` (the `arbiter-worker-logs` corpus
  start date — see the module note on `@corpus_start_date` and
  `Arbiter.Worker.OutputLog`'s moduledoc for the accepted pre-rename loss).

  A workflow-mode (bookkeeping-only) run never opens a Claude session — see
  `Arbiter.Worker.Driver`'s "workflow mode" — so it carries no `session_id`
  and, by design, no transcript. Counting those as capture failures would
  make the rate look broken when nothing is wrong, so they're reported
  separately as `workflow_only_runs` and excluded from `claude_sessions` /
  `capture_rate_pct`. `capture_rate_pct` is `nil` when there are no
  Claude-driven runs in the window (avoids a divide-by-zero misread as 0%).

  Coordinator only. Optional `workspace` (resolved the same way as
  `worker_list` / `task_ready`).
  """
  @spec transcript_capture_stats(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def transcript_capture_stats(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(workspace_id == ^ws_id and started_at >= ^@corpus_start_date)
        |> Ash.read!()

      {claude_sessions, workflow_only} =
        Enum.split_with(runs, &(&1.session_id not in [nil, ""]))

      missing =
        Enum.count(claude_sessions, fn run ->
          not File.regular?(Arbiter.Worker.OutputLog.path_for(run.id))
        end)

      {:ok,
       %{
         corpus_start_date: Date.to_iso8601(DateTime.to_date(@corpus_start_date)),
         total_runs: length(runs),
         claude_sessions: length(claude_sessions),
         transcript_missing: missing,
         workflow_only_runs: length(workflow_only),
         capture_rate_pct: capture_rate_pct(claude_sessions, missing)
       }}
    end
  rescue
    e -> {:error, {:internal, "transcript_capture_stats failed: #{Exception.message(e)}"}}
  end

  defp capture_rate_pct([], _missing), do: nil

  defp capture_rate_pct(claude_sessions, missing) do
    total = length(claude_sessions)
    Float.round((total - missing) / total * 100, 1)
  end

  # ---- Phase 2 dispatch guardrail + opts (docs/mcp-server-design.md §4.3) ----

  defp ensure_dispatch_depth(%Scope{depth: depth}) do
    max = Arbiter.MCP.max_depth()

    if depth < max,
      do: :ok,
      else: {:error, {:unauthorized, "dispatch depth limit (#{max}) reached"}}
  end

  # The opts common to every worker-dispatch tool (dispatch / resume / review):
  # the optional `repo` / `model` overrides plus the child scope depth, minted
  # one level deeper (`depth + 1`) so a chain of dispatches stays tracked.
  defp dispatch_opts(%Scope{tier: tier, depth: depth}, args) do
    {:ok, force_quota} = Tools.fetch_bool(args, "force_quota", false)
    quota_bypass_reason = Tools.fetch_string(args, "force_quota_reason")

    [depth: depth + 1]
    |> Tools.maybe_put_kw(:repo, Tools.fetch_string(args, "repo"))
    |> Tools.maybe_put_kw(:model, Tools.fetch_string(args, "model"))
    |> then(fn opts ->
      if force_quota,
        do:
          opts
          |> Keyword.put(:skip_quota_gate, true)
          |> Keyword.put(:quota_bypass_actor, actor_string(tier))
          |> then(fn opts2 ->
            if quota_bypass_reason,
              do: Keyword.put(opts2, :quota_bypass_reason, quota_bypass_reason),
              else: opts2
          end),
        else: opts
    end)
  end

  defp actor_string(:coordinator), do: "coordinator"
  # :worker-tier scopes never have can_dispatch: true (mcp/scope.ex), so this branch is unreachable in practice.
  defp actor_string(:worker), do: "worker"

  # Map `worker_dispatch` arguments onto `Dispatch.dispatch/2` opts, mirroring the
  # REST `POST /api/workers/dispatch` contract: an explicit `provider` (or deprecated
  # `with_claude`) forces that agent via `agent_type`; `no_agent: true` parks the
  # task `:in_progress` (hand-off path); otherwise the workspace's `agent.type`
  # config is used to pick the first healthy provider.
  defp worker_dispatch_opts(scope, args) do
    base = dispatch_opts(scope, args)

    case dispatch_provider(args) do
      {:error, {:unknown_provider, value}} ->
        # bd-dcvo3n: an explicit but unrecognized `provider` must fail LOUDLY.
        # Falling through to the workspace default here is what silently spawned
        # Claude when `provider: "codex"` hit a server too old to know the value
        # — a substitution the caller had no signal for. Reject it instead.
        {:error,
         {:invalid,
          "unknown provider #{inspect(value)}; valid providers: " <>
            Enum.join(Arbiter.Agents.valid_agent_types(), ", ")}}

      :park ->
        {:ok, Keyword.put(base, :start_driver, false)}

      nil ->
        # No provider specified — resolve from workspace `agent.type` config.
        {:ok, Keyword.put(base, :start_claude, true)}

      type when is_atom(type) ->
        {:ok, base |> Keyword.put(:start_claude, true) |> Keyword.put(:agent_type, type)}
    end
  end

  # Resolve the worker provider from `worker_dispatch` args. Returns `:park` for
  # an explicit `no_agent` opt-in, a provider atom when specified via `provider`
  # or the deprecated `with_claude`, `{:error, {:unknown_provider, value}}` when
  # `provider` is present but unrecognized, or `nil` to signal "use the workspace
  # default" (only when no provider was named at all).
  defp dispatch_provider(args) do
    cond do
      Map.get(args, "no_agent") in [true, "true"] ->
        :park

      provider_given?(args) ->
        provider_atom(Map.get(args, "provider"))

      Map.get(args, "with_claude") in [true, "true"] ->
        :claude

      true ->
        nil
    end
  end

  # A `provider` arg is "given" only when it's a non-blank string. An absent key
  # or an empty/whitespace value means "use the workspace default" (→ `nil`),
  # never an error.
  defp provider_given?(args) do
    case Map.get(args, "provider") do
      p when is_binary(p) -> String.trim(p) != ""
      _ -> false
    end
  end

  # Map an explicit provider string to its atom. An unrecognized (but non-blank)
  # value is a hard error, not a silent fallback to the workspace default.
  defp provider_atom(provider) do
    trimmed = String.trim(provider)

    if trimmed in Arbiter.Agents.valid_agent_types() do
      String.to_existing_atom(trimmed)
    else
      {:error, {:unknown_provider, provider}}
    end
  end

  # `worker_review` is claude-driven by default (a reviewer with no agent has
  # nothing to do), mirroring `POST /api/workers/review`. `with_claude: false`
  # dispatches the review without spawning an agent (the test affordance).
  defp review_claude_flag(opts, args) do
    case Map.get(args, "with_claude") do
      v when v in [false, "false"] -> Keyword.put(opts, :start_claude, false)
      _ -> Keyword.put(opts, :start_claude, true)
    end
  end

  defp dispatch_error_message({:task_closed, id}),
    do: "task #{id} is closed; reopen it before dispatching"

  defp dispatch_error_message(:no_repo_configured), do: "no repos configured for this workspace"

  defp dispatch_error_message({:repo_not_found, repo}),
    do: "repo #{inspect(repo)} is not configured"

  defp dispatch_error_message({:ambiguous_repo, repos}),
    do: "multiple repos available (#{Enum.join(repos, ", ")}); pass `repo` explicitly"

  defp dispatch_error_message({:task_awaiting_review, id}),
    do: "task #{id} is already awaiting review"

  # Resume-specific (`Dispatch.resume/2`).
  defp dispatch_error_message(:no_outpost),
    do: "no preserved worktree for this task — nothing to resume; dispatch it fresh instead"

  defp dispatch_error_message(:repo_unknown),
    do: "could not resolve the repo for this task; pass `repo` explicitly"

  defp dispatch_error_message(other), do: "dispatch failed: #{inspect(other)}"

  # bd-8lq2g7: `{:worker_active, …}` is rendered from the /2 arity so the message
  # can name the parked worker and its subordinate passes, rather than issuing
  # the generic (and, at a review park, destructive) "stop it before resuming".
  defp dispatch_error_message({:worker_active, status}, task_id),
    do: Dispatch.worker_active_message(status, task_id)

  defp dispatch_error_message(other, _task_id), do: dispatch_error_message(other)

  defp validate_positive_integer(nil, _key) do
    {:ok, nil}
  end

  defp validate_positive_integer(value, _key) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_positive_integer(_value, key) do
    {:error, {:invalid, "`#{key}` must be a positive integer"}}
  end

  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  # The dispatch result carries live pids/ports; render the JSON-safe subset (pids
  # inspected to strings), mirroring `ArbiterWeb.Api.WorkerJSON.dispatch/1`. `depth`
  # is the slung worker's scope depth (parent + 1).
  defp serialize_dispatch(result, depth) do
    %{
      task: Tools.serialize_task_summary(result.task),
      worker: %{task_id: result.task.id, pid: inspect(result.worker_pid)},
      machine: %{id: result.machine_id, pid: inspect(result.machine_pid)},
      worktree_path: result.worktree_path,
      claude_started: not is_nil(result.claude_port),
      depth: depth
    }
  end

  defp serialize_worker_summary(snap, cost_usd) do
    meta = Map.get(snap, :meta, %{}) || %{}
    routing = Map.get(meta, :routing_config) || %{}
    model_id = Map.get(meta, :model) || Map.get(routing, :model)
    {resumable, blocked_reason} = Dispatch.resumable_status(snap.task_id)

    %{
      task_id: snap.task_id,
      # bd-8lq2g7: a task can legitimately have TWO live rows — its primary
      # worker plus a merge-queue subordinate pass registered under
      # `<task_id>:fixpass` / `:conflict`. Without these two fields the rows are
      # indistinguishable, which is what made a dead fix pass look like the
      # task's own worker having gone stale.
      registry_key: Map.get(snap, :registry_key) || snap.task_id,
      role: Tools.to_str(Map.get(snap, :role)),
      status: Tools.to_str(snap.status),
      repo: snap.repo,
      started_at: Tools.iso(snap.started_at),
      activity: Map.get(meta, :activity),
      provider: Map.get(meta, :provider) || Map.get(routing, :provider),
      model: Arbiter.Worker.Stats.short_model_name(model_id),
      cost_usd: cost_usd,
      resumable: resumable,
      blocked_reason: blocked_reason
    }
  end

  defp serialize_worker_snapshot(snap, lines) do
    meta = Map.get(snap, :meta, %{}) || %{}
    {resumable, blocked_reason} = Dispatch.resumable_status(snap.task_id)

    output_lines = Map.get(meta, :output_lines, [])
    output_lines = if lines, do: Enum.take(output_lines, -lines), else: output_lines

    %{
      source: "live",
      task_id: snap.task_id,
      # See serialize_worker_summary/2 — a subordinate pass shares the task's id
      # and is only distinguishable by its registry key + role (bd-8lq2g7).
      registry_key: Map.get(snap, :registry_key) || snap.task_id,
      role: Tools.to_str(Map.get(snap, :role)),
      workspace_id: snap.workspace_id,
      repo: snap.repo,
      current_step: snap.current_step,
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      status: Tools.to_str(snap.status),
      started_at: Tools.iso(snap.started_at),
      step_started_at: Tools.iso(Map.get(snap, :step_started_at)),
      mr_ref: Map.get(snap, :mr_ref),
      merger_url: Map.get(snap, :merger_url),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: Tools.iso(Map.get(meta, :last_checked_at)),
      pid: inspect(snap.pid),
      output_lines: output_lines,
      exit_status: Map.get(meta, :exit_status),
      exited_at: Tools.iso(Map.get(meta, :exited_at)),
      result: Map.get(meta, :result),
      failure_reason: stringify_reason(Map.get(meta, :failure_reason)),
      resumable: resumable,
      blocked_reason: blocked_reason
    }
  end

  defp serialize_worker_run(%Arbiter.Workers.Run{} = run, lines) do
    output_lines = run.output_lines || []
    output_lines = if lines, do: Enum.take(output_lines, -lines), else: output_lines

    %{
      source: "history",
      task_id: run.task_id,
      task_title: run.task_title,
      workspace_id: run.workspace_id,
      repo: run.repo,
      worker_type: Tools.to_str(run.worker_type),
      current_step: nil,
      claude_session: false,
      activity: nil,
      status: Tools.to_str(run.status),
      model: run.model,
      started_at: Tools.iso(run.started_at),
      completed_at: Tools.iso(run.completed_at),
      exit_status: run.exit_code,
      output_lines: output_lines,
      failure_reason: run.failure_reason
    }
  end

  defp stringify_reason(nil), do: nil
  defp stringify_reason(v) when is_binary(v), do: v
  defp stringify_reason(v), do: inspect(v)
end
