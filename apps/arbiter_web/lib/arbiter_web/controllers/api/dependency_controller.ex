defmodule ArbiterWeb.Api.DependencyController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Dependency`.

  Routes:

    * `POST   /api/dependencies` — :create  (from_issue_id, to_issue_id, type)
    * `DELETE /api/dependencies/:from/:to[?type=...]` — :delete

  Both actions go through `Arbiter.Tasks.Dependencies` (bd-apj0gq). This used to
  be the *unvalidated* write path — a raw `Ash.create` with no workspace check —
  and it is the one `arb dep add`, `arb dep rm` and `arb create --deps/--parent`
  call, so operators got the weakest guarantees of any surface. It now enforces
  exactly what MCP does: both endpoints resolve, both live in one workspace, no
  gating cycle, and a `parent_of` write re-evaluates the parent's `auto_close`.

  Facade guard failures (`:invalid_type`, `:cross_workspace`, `:cyclic`) render
  as 400 `invalid_request` carrying the facade's message verbatim — the named
  cycle or the two workspace names are the whole point of the error. A missing
  endpoint is 404; resource-level rejections (self-reference, duplicate edge)
  stay 422, unchanged.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Tasks.Dependencies

  action_fallback ArbiterWeb.Api.FallbackController

  def create(conn, params) do
    with {:ok, from} <- require_param(params, "from_issue_id"),
         {:ok, to} <- require_param(params, "to_issue_id"),
         {:ok, type} <- require_param(params, "type"),
         {:ok, dep} <- Dependencies.add(from, to, type, edge_opts(params)) do
      conn
      |> put_status(:created)
      |> render(:show, dependency: dep)
    else
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  def delete(conn, %{"from" => from, "to" => to} = params) do
    case Dependencies.remove(from, to, params["type"]) do
      # A removal that matched nothing keeps its historical 404: the CLI and any
      # other HTTP client have always read it as "there was no such edge", and
      # the facade's `{:ok, 0}` is about the *domain* call being a no-op, not
      # about what a REST client should be told.
      {:ok, 0} ->
        {:error, :not_found}

      {:ok, _removed} ->
        conn
        |> put_status(:no_content)
        |> send_resp(:no_content, "")

      {:error, reason} ->
        {:error, translate(reason)}
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, "#{key} is required"}}
    end
  end

  defp edge_opts(params) do
    []
    |> put_opt(:notes, params["notes"])
    |> put_opt(:created_by, params["created_by"])
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # The facade's guards all carry a message written for a human; hand it
  # straight to the fallback rather than flattening it to "validation failed".
  defp translate({:not_found, _message}), do: :not_found

  defp translate({reason, message}) when is_atom(reason) and is_binary(message),
    do: {:invalid_request, message}

  defp translate(other), do: other
end
