defmodule ArbiterWeb.Api.SchedulerController do
  @moduledoc """
  REST endpoints for board scheduler (autopilot) operations.

  Routes:

    * `POST /api/scheduler/pause` — pause the autopilot
    * `POST /api/scheduler/resume` — resume the autopilot
    * `GET /api/scheduler/status` — get current pause state
  """

  use ArbiterWeb, :controller

  alias Arbiter.Board.Autopilot

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc """
  Pause the board autopilot.

  Returns `{"paused": true}` on success.
  """
  def pause(conn, _params) do
    case Autopilot.pause() do
      :ok ->
        json(conn, %{paused: true})

      {:error, reason} ->
        {:error, {:invalid_request, "pause failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid_request, "pause failed: #{inspect(e)}"}}
  end

  @doc """
  Resume the board autopilot.

  Returns `{"paused": false}` on success.
  """
  def resume(conn, _params) do
    case Autopilot.resume() do
      :ok ->
        json(conn, %{paused: false})

      {:error, reason} ->
        {:error, {:invalid_request, "resume failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid_request, "resume failed: #{inspect(e)}"}}
  end

  @doc """
  Get the current pause state of the board autopilot.

  Returns `{"paused": true|false}`.
  """
  def status(conn, _params) do
    paused? = Autopilot.paused?()
    json(conn, %{paused: paused?})
  rescue
    e ->
      {:error, {:invalid_request, "status check failed: #{inspect(e)}"}}
  end
end
