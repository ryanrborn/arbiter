defmodule ArbiterWeb.Api.FallbackController do
  @moduledoc """
  Translates `{:error, _}` tuples returned by API controller actions into
  consistent JSON error responses.

  Error format (all 4xx responses):

      {"error": {"type": "...", "message": "...", "details": {...}}}

  Where `type` is one of:

    * `"validation_error"` — 422 — `%Ash.Error.Invalid{}` (validation failures)
    * `"not_found"` — 404 — `%Ash.Error.Query.NotFound{}`
    * `"invalid_request"` — 400 — malformed params (bad atom values etc.)

  Anything else falls through to a generic 500.
  """

  use ArbiterWeb, :controller

  def call(conn, {:error, %Ash.Error.Invalid{} = err}) do
    cond do
      contains_not_found?(err) ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{type: "not_found", message: "resource not found", details: %{}}})

      true ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            type: "validation_error",
            message: "validation failed",
            details: ash_invalid_details(err)
          }
        })
    end
  end

  def call(conn, {:error, %Ash.Error.Query.NotFound{}}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{type: "not_found", message: "resource not found", details: %{}}
    })
  end

  def call(conn, {:error, %Ash.Error.Forbidden{} = err}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{type: "forbidden", message: Exception.message(err), details: %{}}
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{type: "not_found", message: "resource not found", details: %{}}
    })
  end

  def call(conn, {:error, {:invalid_request, message}}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{type: "invalid_request", message: message, details: %{}}
    })
  end

  def call(conn, {:error, {:invalid_request, message, details}}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{type: "invalid_request", message: message, details: details}
    })
  end

  def call(conn, {:error, %Ash.Error.Unknown{} = err}) do
    case extract_create_tracker_error(err) do
      %Arbiter.Beads.Issue.CreateTrackerError{} = cte ->
        create_tracker_error_response(conn, cte)

      nil ->
        # Surface the cause when we can but never the full stack.
        causes = err |> Map.get(:errors, []) |> Enum.map(&inspect/1)

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            type: "internal_error",
            message: "internal server error",
            details: %{causes: causes}
          }
        })
    end
  end

  def call(conn, {:error, %Arbiter.Beads.Issue.CreateTrackerError{} = cte}) do
    create_tracker_error_response(conn, cte)
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        type: "internal_error",
        message: "internal server error",
        details: %{reason: inspect(reason)}
      }
    })
  end

  # --- helpers ---

  defp contains_not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp contains_not_found?(_), do: false

  defp ash_invalid_details(%Ash.Error.Invalid{errors: errors}) do
    %{
      errors:
        Enum.map(errors, fn err ->
          %{
            field: error_field(err),
            message: error_message(err)
          }
        end)
    }
  end

  defp error_field(%{field: field}) when not is_nil(field), do: to_string(field)
  defp error_field(%{fields: [field | _]}) when not is_nil(field), do: to_string(field)
  defp error_field(_), do: nil

  defp error_message(err) do
    cond do
      function_exported?(err.__struct__, :message, 1) -> Exception.message(err)
      Map.has_key?(err, :message) and is_binary(err.message) -> err.message
      true -> inspect(err)
    end
  end

  # Ash wraps errors returned from an after_transaction hook inside
  # `%Ash.Error.Unknown{errors: [...]}`. Because our error uses
  # `Splode.Error`, it lands in that list as a struct rather than a
  # stringified `UnknownError.error`. Pull it back out so the caller sees a
  # tracker-specific response.
  defp extract_create_tracker_error(%Ash.Error.Unknown{errors: errors}) do
    Enum.find_value(errors, fn
      %Arbiter.Beads.Issue.CreateTrackerError{} = cte -> cte
      %{error: %Arbiter.Beads.Issue.CreateTrackerError{} = cte} -> cte
      _ -> nil
    end)
  end

  defp extract_create_tracker_error(_), do: nil

  defp create_tracker_error_response(conn, %Arbiter.Beads.Issue.CreateTrackerError{} = cte) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        type: "tracker_upstream_create_failed",
        message: Exception.message(cte),
        details: %{
          bead_id: cte.bead_id,
          tracker_type: Atom.to_string(cte.tracker_type),
          upstream_ref: cte.upstream_ref
        }
      }
    })
  end
end
