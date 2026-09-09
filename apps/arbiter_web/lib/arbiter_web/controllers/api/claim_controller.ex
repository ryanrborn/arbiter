defmodule ArbiterWeb.Api.ClaimController do
  @moduledoc """
  REST endpoints for the tracker-issue ↔ task bridge.

  Claim dispatches through the workspace's configured tracker adapter
  (`github`, `jira`, `shortcut`, …), so `ref` is whatever that tracker uses —
  a GitHub issue number (`"42"`), a Jira key (`"VR-1234"`), a Shortcut story
  id, etc. The adapter defines the assignment-as-claim signal; workspaces
  without a claim-capable tracker get a 400.

  Routes:

    * `POST /api/workspaces/:workspace_id/claim` — claim one issue by ref.
      Body: `{"ref": "42", "force": false, "difficulty": 3, "repo": "org/repo"}`.
      `difficulty` and `repo` are optional and, when given, override whatever
      `Arbiter.Tasks.Claim.claim/3` would otherwise derive from the issue
      (difficulty from labels) or leave unset (repo). Returns the task JSON.
    * `GET  /api/workspaces/:workspace_id/sync/plan` — dry-run reconcile.
      Returns the list of planned actions without acting.
    * `POST /api/workspaces/:workspace_id/sync` — apply reconcile.
      Returns the per-action results.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Tasks.{Claim, Workspace}
  alias ArbiterWeb.Api.IssueJSON

  action_fallback ArbiterWeb.Api.FallbackController

  def claim(conn, %{"workspace_id" => workspace_id} = params) do
    ref = params["ref"]
    force? = truthy?(params["force"])

    with :ok <- require_string(ref, "ref"),
         {:ok, workspace} <- get_workspace(workspace_id),
         {:ok, claim_opts} <- claim_opts(params),
         {:ok, status, task} <-
           Claim.claim(workspace, ref, Keyword.put(claim_opts, :force, force?)) do
      conn
      |> put_status(status_code_for(status))
      |> json(%{
        status: Atom.to_string(status),
        task: IssueJSON.data(task)
      })
    else
      {:error, :tracker_not_supported} ->
        {:error,
         {:invalid_request,
          "workspace has no tracker that supports claim; configure a tracker (github, jira, shortcut)"}}

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

      {:error, _} = err ->
        err
    end
  end

  def plan(conn, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         {:ok, plan} <- Claim.plan(workspace) do
      json(conn, %{data: Enum.map(plan, &serialize_action/1)})
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
    end
  end

  # ---- serialization -----------------------------------------------------

  defp serialize_action({:create, ref, summary}) do
    %{
      action: "create",
      ref: ref,
      title: summary[:title],
      url: summary[:url]
    }
  end

  defp serialize_action({:close, task_id, reason}) do
    %{
      action: "close",
      task_id: task_id,
      reason: reason
    }
  end

  defp serialize_action({:drift, task_id, reason}) do
    %{
      action: "drift",
      task_id: task_id,
      reason: reason
    }
  end

  defp serialize_result({:created, task}),
    do: %{outcome: "created", task: IssueJSON.data(task)}

  defp serialize_result({:closed, task}),
    do: %{outcome: "closed", task: IssueJSON.data(task)}

  defp serialize_result({:drifted, task}),
    do: %{outcome: "drifted", task: IssueJSON.data(task)}

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

  defp claim_opts(params) do
    with {:ok, difficulty} <- fetch_optional_integer(params, "difficulty", 0..5),
         {:ok, repo} <- fetch_optional_string(params, "repo") do
      {:ok, [difficulty: difficulty, repo: repo]}
    end
  end

  defp fetch_optional_integer(params, key, range) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      v when is_integer(v) ->
        integer_in_range(v, key, range)

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> integer_in_range(n, key, range)
          _ -> {:error, {:invalid_request, "#{key} must be an integer"}}
        end

      _ ->
        {:error, {:invalid_request, "#{key} must be an integer"}}
    end
  end

  defp integer_in_range(n, key, first..last//_ = range) do
    if n in range do
      {:ok, n}
    else
      {:error, {:invalid_request, "#{key} #{n} out of range #{first}..#{last}"}}
    end
  end

  defp fetch_optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:invalid_request, "#{key} must be a string"}}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp status_code_for(:created), do: :created
  defp status_code_for(:existing), do: :ok
end
