defmodule ArbiterWeb.Api.DependencyController do
  @moduledoc """
  REST endpoints for `Arbiter.Beads.Dependency`.

  Routes:

    * `POST   /api/dependencies` — :create  (from_issue_id, to_issue_id, type)
    * `DELETE /api/dependencies/:from/:to[?type=...]` — :delete
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.Dependency

  action_fallback ArbiterWeb.Api.FallbackController

  def create(conn, params) do
    attrs = coerce_type(params)

    case Ash.create(
           Dependency,
           Map.take(attrs, ["from_issue_id", "to_issue_id", "type", "created_by", "notes"])
         ) do
      {:ok, dep} ->
        conn
        |> put_status(:created)
        |> render(:show, dependency: dep)

      {:error, _} = err ->
        err
    end
  end

  def delete(conn, %{"from" => from, "to" => to} = params) do
    with {:ok, edges} <- find_edges(from, to, params["type"]) do
      case edges do
        [] ->
          {:error, :not_found}

        deps ->
          Enum.each(deps, &Ash.destroy!/1)

          conn
          |> put_status(:no_content)
          |> send_resp(:no_content, "")
      end
    end
  end

  defp find_edges(from, to, nil) do
    query = Ash.Query.do_filter(Ash.Query.new(Dependency), from_issue_id: from, to_issue_id: to)
    Ash.read(query)
  end

  defp find_edges(from, to, type_str) when is_binary(type_str) do
    case safe_atom(type_str) do
      {:ok, type} ->
        query =
          Ash.Query.do_filter(Ash.Query.new(Dependency),
            from_issue_id: from,
            to_issue_id: to,
            type: type
          )

        Ash.read(query)

      :error ->
        {:error, {:invalid_request, "invalid type: #{inspect(type_str)}"}}
    end
  end

  defp coerce_type(%{"type" => t} = params) when is_binary(t) do
    case safe_atom(t) do
      {:ok, atom} -> Map.put(params, "type", atom)
      :error -> params
    end
  end

  defp coerce_type(params), do: params

  defp safe_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end
end
