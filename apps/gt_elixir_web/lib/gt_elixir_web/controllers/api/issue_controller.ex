defmodule GtElixirWeb.Api.IssueController do
  @moduledoc """
  REST endpoints for `GtElixir.Beads.Issue`.

  Routes:

    * `POST   /api/issues`             — :create
    * `GET    /api/issues`             — :index (filters: status, priority,
                                        issue_type, assignee, workspace_id)
    * `GET    /api/issues/ready`       — :ready (Issue.ready/0)
    * `GET    /api/issues/:id`         — :show
    * `PATCH  /api/issues/:id`         — :update
    * `POST   /api/issues/:id/close`   — :close (body: optional `reason`)
    * `POST   /api/issues/:id/reopen`  — :reopen
  """

  use GtElixirWeb, :controller

  alias GtElixir.Beads.Issue

  action_fallback GtElixirWeb.Api.FallbackController

  @atom_fields ~w(status issue_type tracker_type)a
  @filter_fields ~w(status priority issue_type assignee workspace_id)a

  def index(conn, params) do
    with {:ok, filters} <- build_filters(params) do
      query = Ash.Query.do_filter(Ash.Query.new(Issue), filters)

      case Ash.read(query) do
        {:ok, issues} ->
          render(conn, :index, issues: issues)

        {:error, _} = err ->
          err
      end
    end
  end

  def ready(conn, _params) do
    issues = Issue.ready()
    render(conn, :index, issues: issues)
  end

  def show(conn, %{"id" => id}) do
    case Ash.get(Issue, id) do
      {:ok, issue} -> render(conn, :show, issue: issue)
      {:error, _} = err -> err
    end
  end

  def create(conn, params) do
    attrs =
      params
      |> Map.drop(["id"])
      |> coerce_atoms(@atom_fields)

    case Ash.create(Issue, attrs) do
      {:ok, issue} ->
        conn
        |> put_status(:created)
        |> render(:show, issue: issue)

      {:error, _} = err ->
        err
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.drop(["id", "workspace_id"])
      |> coerce_atoms(@atom_fields)

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, updated} <- Ash.update(issue, attrs) do
      render(conn, :show, issue: updated)
    end
  end

  def close(conn, %{"id" => id} = params) do
    reason = params["reason"]
    args = if reason, do: %{reason: reason}, else: %{}

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, closed} <- Ash.update(issue, args, action: :close) do
      render(conn, :show, issue: closed)
    end
  end

  def reopen(conn, %{"id" => id}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, reopened} <- Ash.update(issue, %{}, action: :reopen) do
      render(conn, :show, issue: reopened)
    end
  end

  # ---- helpers ----

  defp build_filters(params) do
    Enum.reduce_while(@filter_fields, {:ok, []}, fn field, {:ok, acc} ->
      case Map.fetch(params, Atom.to_string(field)) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} ->
          case coerce_filter_value(field, raw) do
            {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp coerce_filter_value(:priority, raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:invalid_request, "priority must be an integer"}}
    end
  end

  defp coerce_filter_value(:priority, raw) when is_integer(raw), do: {:ok, raw}

  defp coerce_filter_value(field, raw) when field in [:status, :issue_type] and is_binary(raw) do
    try do
      {:ok, String.to_existing_atom(raw)}
    rescue
      ArgumentError ->
        {:error, {:invalid_request, "invalid #{field}: #{inspect(raw)}"}}
    end
  end

  defp coerce_filter_value(_, raw) when is_binary(raw), do: {:ok, raw}
  defp coerce_filter_value(_, raw), do: {:ok, raw}

  defp coerce_atoms(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      key = Atom.to_string(field)

      case Map.get(acc, key) do
        nil ->
          acc

        value when is_binary(value) ->
          try do
            Map.put(acc, key, String.to_existing_atom(value))
          rescue
            ArgumentError -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
