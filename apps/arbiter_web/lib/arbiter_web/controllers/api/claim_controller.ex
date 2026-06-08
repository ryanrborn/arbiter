defmodule ArbiterWeb.Api.ClaimController do
  @moduledoc """
  REST endpoints for the GitHub-issue ↔ bead bridge.

  Routes:

    * `POST /api/workspaces/:workspace_id/claim` — claim one issue by ref.
      Body: `{"ref": "42", "force": false}`. Returns the bead JSON.
    * `GET  /api/workspaces/:workspace_id/sync/plan` — dry-run reconcile.
      Returns the list of planned actions without acting.
    * `POST /api/workspaces/:workspace_id/sync` — apply reconcile.
      Returns the per-action results.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.{Claim, Workspace}
  alias ArbiterWeb.Api.IssueJSON

  action_fallback ArbiterWeb.Api.FallbackController

  def claim(conn, %{"workspace_id" => workspace_id} = params) do
    ref = params["ref"]
    force? = truthy?(params["force"])

    with :ok <- require_string(ref, "ref"),
         {:ok, workspace} <- get_workspace(workspace_id),
         {:ok, status, bead} <- Claim.claim(workspace, ref, force: force?) do
      conn
      |> put_status(status_code_for(status))
      |> json(%{
        status: Atom.to_string(status),
        bead: IssueJSON.data(bead)
      })
    else
      {:error, :tracker_not_supported} ->
        {:error, {:invalid_request, "workspace tracker is not github"}}

      {:error, {:already_claimed, body}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            type: "already_claimed",
            message: "this issue has already been claimed by another Arbiter installation",
            details: %{comment: body}
          }
        })

      {:error, {:not_assigned, login}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            type: "not_assigned",
            message:
              "issue is not assigned to workspace user #{inspect(login)}; pass force=true to override",
            details: %{viewer: login}
          }
        })

      {:error, {:invalid_ref, raw}} ->
        {:error, {:invalid_request, "invalid issue ref: #{inspect(raw)}"}}

      {:error, %Arbiter.Trackers.GitHub.Error{} = err} ->
        tracker_error_response(conn, err)

      {:error, _} = err ->
        err
    end
  end

  def plan(conn, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         {:ok, plan} <- Claim.plan(workspace) do
      json(conn, %{data: Enum.map(plan, &serialize_action/1)})
    else
      {:error, %Arbiter.Trackers.GitHub.Error{} = err} ->
        tracker_error_response(conn, err)

      {:error, _} = err ->
        err
    end
  end

  def sync(conn, %{"workspace_id" => workspace_id} = params) do
    dry? = truthy?(params["dry"])

    with {:ok, workspace} <- get_workspace(workspace_id),
         {:ok, plan} <- Claim.plan(workspace) do
      if dry? do
        json(conn, %{data: Enum.map(plan, &serialize_action/1), applied: false})
      else
        {:ok, results} = Claim.apply_plan(workspace, plan)

        json(conn, %{
          data: Enum.map(plan, &serialize_action/1),
          results: Enum.map(results, &serialize_result/1),
          applied: true
        })
      end
    else
      {:error, %Arbiter.Trackers.GitHub.Error{} = err} ->
        tracker_error_response(conn, err)

      {:error, _} = err ->
        err
    end
  end

  # ---- serialization -----------------------------------------------------

  defp serialize_action({:create, ref, summary}) do
    %{
      action: "create",
      ref: ref,
      title: summary[:title],
      html_url: summary[:html_url]
    }
  end

  defp serialize_action({:close, bead_id, reason}) do
    %{
      action: "close",
      bead_id: bead_id,
      reason: reason
    }
  end

  defp serialize_result({:created, bead}),
    do: %{outcome: "created", bead: IssueJSON.data(bead)}

  defp serialize_result({:closed, bead}),
    do: %{outcome: "closed", bead: IssueJSON.data(bead)}

  defp serialize_result({:error, action, reason}) do
    %{
      outcome: "error",
      action: serialize_action(action),
      reason: inspect(reason)
    }
  end

  # ---- helpers ----------------------------------------------------------

  defp get_workspace(id) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> {:ok, ws}
      {:error, _} = err -> err
    end
  end

  defp require_string(v, _name) when is_binary(v) and v != "", do: :ok

  defp require_string(_v, name),
    do: {:error, {:invalid_request, "#{name} is required"}}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp status_code_for(:created), do: :created
  defp status_code_for(:existing), do: :ok

  defp tracker_error_response(conn, %Arbiter.Trackers.GitHub.Error{} = err) do
    http_status =
      case err.kind do
        :config_missing -> :bad_request
        :unauthenticated -> :unauthorized
        :forbidden -> :forbidden
        :not_found -> :not_found
        :validation_failed -> :unprocessable_entity
        _ -> :bad_gateway
      end

    conn
    |> put_status(http_status)
    |> json(%{
      error: %{
        type: "tracker_error",
        message: err.message,
        details: %{kind: Atom.to_string(err.kind), status: err.status}
      }
    })
  end
end
