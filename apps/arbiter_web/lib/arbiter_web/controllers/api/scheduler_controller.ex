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

  Returns `{"paused": true, "changed_at": iso8601, "changed_by": "api"}` on success.
  """
  def pause(conn, _params) do
    case Autopilot.pause(Autopilot, "api") do
      :ok ->
        json(conn, status_json())

      {:error, reason} ->
        {:error, {:invalid_request, "pause failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid_request, "pause failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid_request, "pause failed: process error #{inspect(reason)}"}}
  end

  @doc """
  Resume the board autopilot.

  Returns `{"paused": false, "changed_at": iso8601, "changed_by": "api"}` on success.
  """
  def resume(conn, _params) do
    case Autopilot.resume(Autopilot, "api") do
      :ok ->
        json(conn, status_json())

      {:error, reason} ->
        {:error, {:invalid_request, "resume failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid_request, "resume failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid_request, "resume failed: process error #{inspect(reason)}"}}
  end

  @doc """
  Get the current pause state of the board autopilot.

  Returns `{"paused": true|false, "changed_at": iso8601|null, "changed_by": string|null}`.
  """
  def status(conn, _params) do
    json(conn, status_json())
  rescue
    e ->
      {:error, {:invalid_request, "status check failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid_request, "status check failed: process error #{inspect(reason)}"}}
  end

  defp status_json do
    status = Autopilot.status()

    %{
      paused: status.paused?,
      changed_at: status.changed_at,
      changed_by: status.changed_by
    }
  end
end
