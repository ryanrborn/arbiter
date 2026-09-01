defmodule ArbiterWeb.Api.QueueController do
  @moduledoc """
  REST endpoints for graph-queue operations (C5 of #482).

  Routes:

    * `POST /api/queue/:task_id/resume` — resume a paused branch by re-dispatching
      the failed task. The Conductor that owns this task is found automatically via
      the `ConductorSupervisor` Registry.
    * `POST /api/queue/:task_id/retry_auto_resolve` — re-arm one more auto-resolve
      attempt for a task whose merge Watchdog is parked after exhausting
      `max_auto_resolve_attempts` on a `:ci_failed` block (bd-bspakl).
    * `POST /api/queue/:task_id/restart_watchdog` — mint a fresh Watchdog for a
      task whose Watchdog died outright, attached to the MR its worker already
      has open (bd-8jixav). Distinct from the above, which only re-arms an
      already-running Watchdog.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Workflows.Conductor
  alias Arbiter.Worker.Watchdog

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc """
  Resume a paused graph branch.

  The task id comes from the URL path parameter. Body is ignored.

  Returns `{"resumed": true, "task_id": "..."}` on success.

  Errors:

    * 404 — no running conductor has this task in its failed set.
    * 400 — task is a conductor member but has not failed, or re-dispatch
      encountered an error.
  """
  def resume(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    case Conductor.resume_task(task_id) do
      :ok ->
        json(conn, %{resumed: true, task_id: task_id})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :not_failed} ->
        {:error,
         {:invalid_request,
          "task #{task_id} has not failed in any running graph — nothing to resume"}}

      {:error, :dispatch_failed} ->
        {:error, {:invalid_request, "re-dispatch of #{task_id} failed — check worker logs"}}

      {:error, reason} ->
        {:error, {:invalid_request, "resume failed: #{inspect(reason)}"}}
    end
  end

  def resume(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  @doc """
  Re-arm one more auto-resolve attempt on a task's merge Watchdog.

  Only meaningful once the Watchdog has exhausted `max_auto_resolve_attempts`
  on a `:ci_failed` block and parked indefinitely (bd-bspakl) — the dashboard's
  "Retry" action for that escalation calls this instead of the worker resume
  action, which is correctly refused in this state.

  Returns `{"retried": true, "task_id": "..."}` on success.

  Errors:

    * 404 — no Watchdog is currently running for this task.
    * 400 — the Watchdog exists but isn't parked on an exhausted `:ci_failed`
      block, so there's nothing to re-arm.
  """
  def retry_auto_resolve(conn, %{"task_id" => task_id})
      when is_binary(task_id) and task_id != "" do
    case Watchdog.retry_auto_resolve(task_id) do
      :ok ->
        json(conn, %{retried: true, task_id: task_id})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :not_parked_on_ci_failed} ->
        {:error,
         {:invalid_request,
          "task #{task_id} isn't parked on an exhausted :ci_failed block — nothing to re-arm"}}

      {:error, :busy} ->
        {:error, {:busy, "task #{task_id}'s watchdog is busy polling — try again in a moment"}}
    end
  end

  def retry_auto_resolve(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  @doc """
  Mint a **fresh** merge Watchdog for a task whose Watchdog has died, attached
  to the MR its worker already has open (bd-8jixav).

  A Watchdog is a `:temporary` process — when it crashes it is gone for good,
  silently — leaving the worker parked at `:awaiting_review` with a genuinely
  open MR nothing is polling. `retry_auto_resolve` cannot recover that: it
  messages an already-running Watchdog and 404s once the process is gone.

  Returns `{"restarted": true, "task_id": "..."}` on success.

  Errors:

    * 404 — no worker is registered for this task; there is nothing to attach
      a Watchdog to.
    * 409 — a Watchdog is already running. Refused rather than stacked: two
      Watchdogs polling one MR would race the merge and double-dispatch fix
      passes.
    * 400 — the worker is alive but not parked at `:awaiting_review`, or
      parked without an MR ref / adapter to watch.
    * 503 — the worker didn't answer in time.
  """
  def restart_watchdog(conn, %{"task_id" => task_id})
      when is_binary(task_id) and task_id != "" do
    case Watchdog.restart(task_id) do
      :ok ->
        json(conn, %{restarted: true, task_id: task_id})

      {:error, :no_worker} ->
        {:error, :not_found}

      {:error, :already_running} ->
        {:error,
         {:conflict,
          "a merge watchdog is already running for task #{task_id} — restarting would put " <>
            "two of them on one MR"}}

      {:error, {:not_parked, status}} ->
        {:error,
         {:invalid_request,
          "task #{task_id}'s worker is #{status}, not awaiting_review — it has no open MR " <>
            "for a watchdog to watch"}}

      {:error, reason} when reason in [:no_mr_ref, :no_adapter] ->
        {:error,
         {:invalid_request,
          "task #{task_id}'s worker is parked at awaiting_review but recorded no " <>
            "#{if reason == :no_mr_ref, do: "MR ref", else: "merger adapter"} — there is " <>
            "nothing to watch"}}

      {:error, :busy} ->
        {:error,
         {:busy, "task #{task_id}'s worker did not answer in time — try again in a moment"}}

      {:error, {:start_failed, reason}} ->
        {:error, {:invalid_request, "watchdog restart failed: #{inspect(reason)}"}}
    end
  end

  def restart_watchdog(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end
end
