defmodule ArbiterWeb.Api.WorkerController do
  @moduledoc """
  REST endpoints for worker lifecycle. The arb CLI calls `dispatch/2` to
  start work on a task; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running workers.

  Routes:

    * `POST /api/workers/dispatch`           — :dispatch (body: `task_id`, optional `repo`, `provider`).
      `provider` is `"claude"` | `"gemini"` (deprecated aliases: `with_claude` /
      `with_gemini` booleans). With a provider a worker subprocess works the task
      and the Driver closes it on `arb done`; with `no_agent` the task parks in
      `:in_progress` (no Driver).
    * `POST /api/workers/review`          — :review.
      Two shapes: (a) `task_id` (+ optional `repo`) dispatches a review-only
      worker against the PR/MR linked to a task — no worktree, no per-task
      branch, no merge-queue route, always claude-driven. (b) `pr` (URL or
      number, + optional `repo`/`workspace`) reviews an **external / non-arbiter
      PR** via the MR adapter (`Arbiter.Reviews.ExternalReview`): no task, no
      branch — findings + a verdict are posted to that PR.
    * `GET  /api/workers`                 — :index (list active workers)
    * `GET  /api/workers/:task_id`        — :show (full snapshot inc. recent output).
      When no live worker exists for the task, falls back to the most recent
      `Arbiter.Workers.Run` row so finished/exited runs stay inspectable.
    * `POST /api/workers/:task_id/resume` — :resume (bd-1z7624, #472).
      Session-level resume: re-spawns the worker continuing the task's PRIOR
      Claude session (`claude --print --resume <session_id>`) in the SAME
      preserved worktree. Refuses (pointing at `arb dispatch`) when no prior
      session/worktree exists — never silently starts fresh.
    * `POST /api/workers/:task_id/stop`   — :stop (terminate worker cleanly)
    * `GET  /api/workers/:task_id/log`    — :log (full, uncapped durable
      transcript of the task's most recent run; the audit source of record).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Reviews.ExternalReview
  alias Arbiter.Worker
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  def dispatch(conn, params) do
    case params do
      %{"task_id" => task_id} when is_binary(task_id) and task_id != "" ->
        opts = dispatch_opts(params)

        case Dispatch.dispatch(task_id, opts) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> render(:dispatch, result: result)

          {:error, {:task_not_found, _}} ->
            {:error, :not_found}

          {:error, {:task_closed, _}} ->
            {:error,
             {:invalid_request, "task is closed; reopen it before dispatching",
              %{task_id: task_id}}}

          {:error, {:task_awaiting_review, _}} ->
            {:error,
             {:invalid_request,
              "task is already awaiting review; the Watchdog will close it on MR merge",
              %{task_id: task_id}}}

          {:error, :no_repo_configured} ->
            {:error,
             {:invalid_request,
              "no repos configured — add at least one repo to your workspace config " <>
                "(repo_paths) or application env (:arbiter, :repo_paths), " <>
                "or pass a repo explicitly: `arb issue dispatch #{task_id} <repo>`",
              %{task_id: task_id}}}

          {:error, {:repo_not_found, repo}} ->
            {:error,
             {:invalid_request,
              "repo #{inspect(repo)} is not in :repo_paths — check your workspace config or " <>
                "application env (:arbiter, :repo_paths)", %{task_id: task_id, repo: repo}}}

          {:error, {:ambiguous_repo, repos}} ->
            {:error,
             {:invalid_request,
              "multiple repos available (#{Enum.join(repos, ", ")}) — specify one: " <>
                "`arb issue dispatch #{task_id} <repo>`",
              %{task_id: task_id, available_repos: repos}}}

          {:error, reason} ->
            {:error, {:server_error, "dispatch failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "task_id is required", %{}}}
    end
  end

  @doc """
  Dispatch a review-only issue. The task is slung with `review: true`,
  which forces the `CodeReview` workflow, skips worktree provisioning, swaps
  the work prompt for the review prompt, and tags the worker as
  `review_only` so completion does not fan out to the merge queue/merger.

  Always claude-driven (`start_claude: true`) — a review without an agent has
  nothing to do.
  """
  def review(conn, params) do
    case params do
      # External / non-arbiter PR review (bd-d4ealy): no task, no branch — point
      # the reviewer at an arbitrary PR by URL/number through the MR adapter.
      %{"pr" => pr} when is_binary(pr) and pr != "" ->
        review_external(conn, params)

      %{"task_id" => task_id} when is_binary(task_id) and task_id != "" ->
        opts = review_opts(params)

        case Dispatch.dispatch(task_id, opts) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> render(:dispatch, result: result)

          {:error, {:task_not_found, _}} ->
            {:error, :not_found}

          {:error, {:task_closed, _}} ->
            {:error,
             {:invalid_request, "task is closed; reopen it before reviewing", %{task_id: task_id}}}

          {:error, {:task_awaiting_review, _}} ->
            {:error,
             {:invalid_request,
              "task is already awaiting review; a Watchdog is active and will close it on MR merge",
              %{task_id: task_id}}}

          {:error, reason} ->
            {:error, {:server_error, "review dispatch failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "task_id or pr is required", %{}}}
    end
  end

  # External / non-arbiter PR review (bd-d4ealy). Validates synchronously
  # (workspace + MR adapter + PR ref) so a bad PR / unsupported strategy 422s
  # immediately, then runs the CodeReview adapter workflow in the background and
  # acks with the resolved mr_ref + link. `repo`/`workspace` are optional.
  defp review_external(conn, params) do
    opts =
      [
        pr: params["pr"],
        repo: params["repo"],
        workspace: params["workspace"],
        # report_only (propose) / automation flow through to ExternalReview, which
        # resolves whether the review posts to the PR or only reports (bd-36qzgx).
        automation: params["automation"]
      ]
      |> maybe_put_report_only(params["report_only"])

    case ExternalReview.dispatch(opts) do
      {:ok, ack} ->
        conn
        |> put_status(:created)
        |> json(%{data: ack})

      {:error, reason} ->
        {:error, {:invalid_request, ExternalReview.describe_error(reason), %{pr: params["pr"]}}}
    end
  end

  defp maybe_put_report_only(opts, true), do: Keyword.put(opts, :report_only, true)
  defp maybe_put_report_only(opts, "true"), do: Keyword.put(opts, :report_only, true)
  defp maybe_put_report_only(opts, _), do: opts

  @doc """
  Resume a stopped worker at the SESSION level (bd-1z7624, #472). Re-spawns the
  worker continuing the task's PRIOR Claude session via `claude --print --resume
  <session_id>` in the SAME preserved worktree, so the original mind picks up
  where it left off — distinct from `arb dispatch` (a fresh session + worktree).

  Backed by `Arbiter.Worker.Dispatch.resume_session/2`, which looks up the
  task's most-recent captured `session_id` + preserved worktree and re-spawns
  through the bd-t9uq25 resume path. Refuses with a clear error (pointing at
  `arb dispatch`) when there is no resumable prior session or worktree — it
  never silently starts fresh. Always claude-driven; renders the same payload
  as `dispatch/2`.
  """
  def resume(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    opts = resume_opts(params)

    case Dispatch.resume_session(task_id, opts) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> render(:dispatch, result: result)

      {:error, {:task_not_found, _}} ->
        {:error, :not_found}

      {:error, {:task_closed, _}} ->
        {:error,
         {:invalid_request, "task is closed; reopen it before resuming", %{task_id: task_id}}}

      {:error, :no_outpost} ->
        {:error,
         {:invalid_request,
          "no preserved worktree for this task — nothing to resume; start fresh with " <>
            "`arb dispatch #{task_id}`", %{task_id: task_id}}}

      {:error, :no_session} ->
        {:error,
         {:invalid_request,
          "no prior Claude session recorded for this task — nothing to resume at the " <>
            "session level; start fresh with `arb dispatch #{task_id}`", %{task_id: task_id}}}

      {:error, :repo_unknown} ->
        {:error,
         {:invalid_request,
          "could not resolve the repo for this task; pass it explicitly: `arb worker resume <task> <repo>`",
          %{task_id: task_id}}}

      {:error, {:acolyte_active, status}} ->
        {:error,
         {:invalid_request,
          "a worker is still active for this task (#{status}); stop it before resuming",
          %{task_id: task_id}}}

      {:error, reason} ->
        {:error, {:server_error, "resume failed", %{reason: inspect(reason)}}}
    end
  end

  def resume(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  def index(conn, _params) do
    children = Worker.list_children()
    task_ids = Enum.map(children, & &1.task_id)
    costs = Arbiter.Worker.Stats.task_costs_usd(task_ids)
    render(conn, :index, children: children, costs: costs)
  end

  def show(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    case Worker.whereis(task_id) do
      nil ->
        show_historical(conn, task_id)

      pid ->
        case Worker.state(pid) do
          %{} = snap ->
            render(conn, :show, snapshot: Map.put(snap, :pid, pid))

          _ ->
            show_historical(conn, task_id)
        end
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # No live worker for this task — fall back to the most recent durable
  # `Run` row so a finished/exited run is still inspectable. 404 only when no
  # run was ever recorded.
  defp show_historical(conn, task_id) do
    case latest_run(task_id) do
      %Run{} = run -> render(conn, :show, run: run)
      nil -> {:error, :not_found}
    end
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  def stop(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    case Worker.stop(task_id, :normal) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{task_id: task_id, stopped: true})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def stop(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # Full, uncapped durable transcript for the task's most recent run. Resolves
  # the latest `Run` row, then reads its on-disk transcript via `OutputLog`.
  # `exists` distinguishes "no file yet / never captured" (false, lines [])
  # from "captured but empty" (true, lines []). 404 only when no run exists.
  def log(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    case latest_run(task_id) do
      %Run{} = run ->
        {exists, lines} =
          case OutputLog.read_lines(run.id) do
            {:ok, lines} -> {true, lines}
            {:error, _} -> {false, []}
          end

        json(conn, %{
          data: %{
            task_id: run.task_id,
            run_id: run.id,
            path: OutputLog.path_for(run.id),
            exists: exists,
            line_count: length(lines),
            lines: lines
          }
        })

      nil ->
        {:error, :not_found}
    end
  end

  def log(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # Map request params onto `Dispatch.dispatch/2` opts.
  #
  # Worker resolution:
  #   * `no_agent`    → dry dispatch: park the task in `:in_progress` for a hand
  #     to attach. The Driver is suppressed (`start_driver: false`) so the
  #     no-op Work workflow doesn't race to a bogus `:closed`.
  #   * `provider`    → force the named provider (`"claude"` | `"gemini"`),
  #     regardless of workspace's `agent.type`. `agent_type: <atom>` overrides
  #     routing.
  #   * `with_claude` / `with_gemini` → DEPRECATED aliases for
  #     `provider: "claude"` / `provider: "gemini"`. Still honored so existing
  #     scripts and the MCP `with_claude` alias don't break.
  #   * none          → use the workspace's `agent.type` config (the default).
  #     Resolves via `Agents.for_workspace`, picking the provider the workspace
  #     is configured for.
  defp dispatch_opts(params) do
    base =
      [repo: params["repo"]]
      |> add_model_override(params["model"])

    worker_opts =
      cond do
        truthy(params["no_agent"]) == true ->
          [start_driver: false]

        provider = normalize_provider(params["provider"]) ->
          [start_claude: true, agent_type: provider]

        truthy(params["with_claude"]) == true ->
          [start_claude: true, agent_type: :claude]

        truthy(params["with_gemini"]) == true ->
          [start_claude: true, agent_type: :gemini]

        true ->
          [start_claude: true]
      end

    (base ++ worker_opts)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # Normalize the `provider` request field to the `:agent_type` atom Dispatch
  # expects. Unknown / missing values fall through to nil so the alias / default
  # branches still apply.
  defp normalize_provider("claude"), do: :claude
  defp normalize_provider("gemini"), do: :gemini
  defp normalize_provider(_), do: nil

  # Map request params onto `Dispatch.resume_session/2` opts. Repo is optional —
  # resume falls back to the task's most recent run's repo when omitted.
  # `--model` is an optional per-dispatch override, same as dispatch.
  defp resume_opts(params) do
    [repo: params["repo"]]
    |> add_model_override(params["model"])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # `--model` from the CLI is forwarded into `Dispatch.dispatch/2` so the worker
  # session runs on the named model regardless of workspace/routing config.
  # Only honored when start_claude is true (no agent ⇒ no model to pick).
  defp add_model_override(opts, model) when is_binary(model) and model != "" do
    Keyword.put(opts, :model, model)
  end

  defp add_model_override(opts, _), do: opts

  # Review-only dispatch. `review: true` cascades into Dispatch: it pulls the
  # CodeReview workflow, suppresses worktree provisioning, swaps the prompt,
  # and stamps `review_only` into the worker's meta so completion doesn't
  # fan out to the merge queue.
  #
  # `with_claude` defaults to true — a reviewer with no agent has nothing to
  # do. Tests pass `with_claude: false` to dispatch a review without spawning
  # a Claude subprocess.
  defp review_opts(params) do
    base = [repo: params["repo"], review: true]

    start_claude =
      case truthy(params["with_claude"]) do
        false -> false
        _ -> true
      end

    base
    |> Keyword.put(:start_claude, start_claude)
    |> then(fn opts ->
      # Suppress the Driver only when no Claude subprocess is involved
      # (test-mode dispatch with with_claude: false). For real reviews
      # (start_claude: true), the Driver runs in claude_driven mode and
      # is the sole component that closes the task on :completed.
      if start_claude, do: opts, else: Keyword.put(opts, :start_driver, false)
    end)
    |> add_model_override(params["model"])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp truthy(nil), do: nil
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(false), do: false
  defp truthy("false"), do: false
  defp truthy(_), do: nil
end
