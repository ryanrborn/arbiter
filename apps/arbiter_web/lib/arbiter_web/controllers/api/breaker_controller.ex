defmodule ArbiterWeb.Api.BreakerController do
  @moduledoc """
  REST endpoints for the shared circuit breaker (bd-5jr49o) — the transport
  behind `arb breaker list` / `arb breaker reset`.

  Routes:

    * `GET  /api/breakers` — live breaker state plus the static registry of
      gated call sites (`?workspace=`, `?kind=`, `?open_only=true`)
    * `POST /api/breakers/reset` — close one breaker by `signature`, or every
      breaker matching `workspace` / `kind` when `all` is set

  The registry is returned unconditionally so a freshly-restarted server still
  answers "what is gated?" before any breaker has fired.
  """

  use ArbiterWeb, :controller

  alias Arbiter.CircuitBreaker

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc "Live breaker state plus the call-site registry."
  def index(conn, params) do
    filters =
      []
      |> maybe_put(:workspace_id, blank_to_nil(params["workspace"]))
      |> maybe_put(:kind, resolve_kind(params["kind"]))
      |> maybe_put(:open_only, params["open_only"] in ["true", true])

    breakers = CircuitBreaker.list(filters)

    json(conn, %{
      breakers: Enum.map(breakers, &serialize/1),
      open_count: Enum.count(breakers, & &1.open?),
      call_sites: Enum.map(CircuitBreaker.call_sites(), &serialize_site/1)
    })
  end

  @doc "Close one breaker by signature, or a whole scope with `all`."
  def reset(conn, params) do
    case blank_to_nil(params["signature"]) do
      nil ->
        if params["all"] in ["true", true] do
          filters =
            []
            |> maybe_put(:workspace_id, blank_to_nil(params["workspace"]))
            |> maybe_put(:kind, resolve_kind(params["kind"]))

          {:ok, count} = CircuitBreaker.reset_all(filters)
          json(conn, %{reset: count})
        else
          {:error,
           {:invalid_request,
            "pass `signature` to reset one breaker, or `all: true` to reset a scope"}}
        end

      signature ->
        case CircuitBreaker.reset(signature) do
          :ok ->
            json(conn, %{reset: 1, signature: signature})

          {:error, :not_found} ->
            {:error, {:invalid_request, "no breaker with signature #{signature}"}}
        end
    end
  end

  # The registry is a closed set, so a kind name resolves to an existing atom
  # rather than minting one from user input.
  defp resolve_kind(nil), do: nil
  defp resolve_kind(""), do: nil

  defp resolve_kind(name) when is_binary(name) do
    case Enum.find(CircuitBreaker.call_sites(), &(to_string(&1.kind) == name)) do
      nil -> nil
      site -> site.kind
    end
  end

  defp resolve_kind(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, _key, false), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp serialize(entry) do
    %{
      signature: entry.signature,
      workspace_id: entry.workspace_id,
      kind: to_string(entry.kind),
      subject: entry.subject,
      count: entry.count,
      suppressed: entry.suppressed,
      limit: entry.limit,
      window_ms: entry.window_ms,
      open: entry.open?,
      first_at: iso(entry.first_at),
      last_at: iso(entry.last_at),
      tripped_at: iso(entry.tripped_at)
    }
  end

  defp serialize_site(site) do
    %{
      kind: to_string(site.kind),
      module: inspect(site.module),
      description: site.description,
      limit: site.limit,
      window_ms: site.window_ms
    }
  end

  defp iso(nil), do: nil

  defp iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
