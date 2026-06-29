defmodule ArbiterWeb.Api.QueueController do
  @moduledoc """
  REST endpoints for graph-queue operations (C5 of #482).

  Routes:

    * `POST /api/queue/:task_id/resume` — resume a paused branch by re-dispatching
      the failed task. The Conductor that owns this task is found automatically via
      the `ConductorSupervisor` Registry.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Workflows.Conductor

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
end
