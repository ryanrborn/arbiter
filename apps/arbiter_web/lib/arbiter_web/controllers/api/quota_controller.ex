defmodule ArbiterWeb.Api.QuotaController do
  @moduledoc """
  `GET /api/quota` — the current quota state for a workspace. Backs `arb quota`.

  Resolves the target workspace from `?workspace=<id|name>`, falling back to
  the installation default.

    * `claude` — the latest snapshot the local proxy captured off Claude worker
      traffic; `null` before the first proxied request.
    * `codex` — fetched live from OpenAI's rate-limit endpoint using the
      `codex` CLI's stored token; `null` (with a `codex_message`) when Codex
      isn't authenticated or the usage API is unavailable.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  def show(conn, params) do
    case resolve_workspace_id(Map.get(params, "workspace")) do
      {:ok, ws_id} ->
        codex = Quota.Codex.fetch(ws_id)

        render(conn, :show,
          workspace_id: ws_id,
          claude: Quota.serialize(ws_id),
          codex: codex.codex,
          codex_message: codex.message
        )

      {:error, message} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{type: "not_found", message: message}})
    end
  end

  # Explicit `?workspace=` (id, then name) wins; else the installation default.
  defp resolve_workspace_id(nil), do: default_workspace_id()
  defp resolve_workspace_id(""), do: default_workspace_id()

  defp resolve_workspace_id(ref) do
    with :error <- by_id(ref), :error <- by_name(ref) do
      {:error, "workspace #{inspect(ref)} not found"}
    end
  end

  defp by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_workspace_id do
    case Quota.default_workspace_id() do
      {:ok, id} -> {:ok, id}
      {:error, :no_workspaces} -> {:error, "no workspaces exist on this installation"}
      {:error, _} -> {:error, "no default workspace; pass ?workspace=<id>"}
    end
  end
end
