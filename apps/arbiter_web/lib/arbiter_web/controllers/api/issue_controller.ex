defmodule ArbiterWeb.Api.IssueController do
  @moduledoc """
  REST endpoints for `Arbiter.Beads.Issue`.

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

  use ArbiterWeb, :controller

  alias Arbiter.Beads.Issue

  action_fallback ArbiterWeb.Api.FallbackController

  @atom_fields ~w(status issue_type tracker_type)a
  @filter_fields ~w(status priority difficulty issue_type assignee workspace_id)a

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

  def ready(conn, params) do
    opts =
      case params["workspace_id"] do
        ws when is_binary(ws) and ws != "" -> [workspace_id: ws]
        _ -> []
      end

    issues = Issue.ready(opts)
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
        case Arbiter.Beads.Issue.Changes.CreateUpstream.last_error() do
          nil ->
            conn
            |> put_status(:created)
            |> render(:show, issue: issue)

          err ->
            upstream_failure_response(conn, issue.id, err)
        end

      {:error, _} = err ->
        err
    end
  end

  # The bead was created locally but the upstream create (or write-back of
  # the returned ref) failed. We return 502 Bad Gateway so the CLI exits
  # non-zero, but we include the bead body in the response so the user can
  # see what got persisted and re-link manually if needed.
  defp upstream_failure_response(conn, bead_id, err) do
    issue_body =
      case Ash.get(Issue, bead_id) do
        {:ok, issue} -> ArbiterWeb.Api.IssueJSON.data(issue)
        _ -> %{id: bead_id}
      end

    conn
    |> put_status(:bad_gateway)
    |> json(%{
      "issue" => issue_body,
      "error" => %{
        "type" => to_string(err.kind),
        "message" => err.message,
        "details" => %{
          "bead_id" => bead_id,
          "tracker_type" => err |> Map.get(:tracker_type) |> tracker_type_str(),
          "tracker_ref" => Map.get(err, :tracker_ref)
        }
      }
    })
  end

  defp tracker_type_str(nil), do: nil
  defp tracker_type_str(t) when is_atom(t), do: to_string(t)
  defp tracker_type_str(t), do: t

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

  defp coerce_filter_value(field, raw)
       when field in [:priority, :difficulty] and is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:invalid_request, "#{field} must be an integer"}}
    end
  end

  defp coerce_filter_value(field, raw)
       when field in [:priority, :difficulty] and is_integer(raw),
       do: {:ok, raw}

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
