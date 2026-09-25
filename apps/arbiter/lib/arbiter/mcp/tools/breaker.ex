defmodule Arbiter.MCP.Tools.Breaker do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the shared circuit breaker (bd-5jr49o):
  `breaker_list` / `breaker_reset`.

  Coordinator-only. A tripped breaker is a fleet-level "stop doing this"
  decision, and re-arming it is the coordinator's call — a worker clearing the
  breaker that is suppressing its own re-file loop is precisely the failure
  mode the breaker exists to prevent.

  `breaker_list` always returns the static `call_sites` registry alongside the
  live counters, so the answer to "is anything gated at all?" is available on a
  freshly-restarted server where no breaker has fired yet.

  Both also carry the auth-shaped dispatch hold (`Arbiter.Agents.AuthHold`,
  bd-21bmdh): `breaker_list` reports every open hold and live streak under
  `auth_holds`, and `breaker_reset` with `provider` clears one.

  `breaker_list` also reports `credential_watchdog` (bd-3kg53c) — every
  adapter `Arbiter.Agents.CredentialWatchdog` still has an outstanding expiry
  for, even one an `AuthHold` reset already covers implicitly (it clears the
  watchdog mark too, whether or not the hold itself was open — see
  `AuthHold.reset/2`). This is what makes a `:periodic_probe`-only expiry (no
  worker ever died, so it never shows under `auth_holds`) visible at all: the
  answer to "is this adapter actually stuck" should never require a restart
  to find out.
  """

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.CircuitBreaker
  alias Arbiter.MCP.Scope

  @doc """
  Current circuit-breaker state plus the registry of gated call sites.
  Optional `workspace`, `kind`, `open_only`. Coordinator only.
  """
  @spec breaker_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def breaker_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Arbiter.MCP.Tools.authorized_workspace(scope, args),
         {:ok, kind} <- kind_arg(args) do
      filters =
        []
        |> maybe_put(:workspace_id, ws_id)
        |> maybe_put(:kind, kind)
        |> maybe_put(:open_only, truthy(Map.get(args, "open_only")))

      breakers = CircuitBreaker.list(filters)

      {:ok,
       %{
         breakers: Enum.map(breakers, &serialize/1),
         open_count: Enum.count(breakers, & &1.open?),
         call_sites: Enum.map(CircuitBreaker.call_sites(), &serialize_site/1),
         # bd-21bmdh: host-wide (credentials are per provider, not per
         # workspace), so unfiltered by `workspace` / `kind`.
         auth_holds: Enum.map(AuthHold.list(), &AuthHold.serialize/1),
         credential_watchdog: CredentialWatchdog.list()
       }}
    end
  end

  @doc """
  Close one breaker by `signature`, or every breaker matching `workspace` /
  `kind` when `all` is set. Coordinator only.
  """
  @spec breaker_reset(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def breaker_reset(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Arbiter.MCP.Tools.authorized_workspace(scope, args),
         {:ok, kind} <- kind_arg(args) do
      case Map.get(args, "signature") do
        _ when is_map_key(args, "provider") ->
          reset_auth_hold(Map.get(args, "provider"))

        sig when is_binary(sig) and sig != "" ->
          case CircuitBreaker.reset(sig) do
            :ok -> {:ok, %{reset: 1, signature: sig}}
            {:error, :not_found} -> {:error, {:not_found, "no breaker with signature #{sig}"}}
          end

        _ ->
          if truthy(Map.get(args, "all")) do
            filters = [] |> maybe_put(:workspace_id, ws_id) |> maybe_put(:kind, kind)
            {:ok, count} = CircuitBreaker.reset_all(filters)
            {:ok, %{reset: count}}
          else
            {:error,
             {:invalid, "pass `signature` to reset one breaker, or `all: true` to reset a scope"}}
          end
      end
    end
  end

  # bd-21bmdh: clear one provider's auth-shaped dispatch hold (and the
  # CredentialWatchdog mark it set). `reset: 0` when it was not open.
  defp reset_auth_hold(name) do
    case AuthHold.resolve_provider(name) do
      {:ok, adapter} ->
        {:ok, cleared} = AuthHold.reset(adapter)
        {:ok, %{reset: length(cleared), auth_hold: name}}

      :error ->
        {:error,
         {:invalid,
          "unknown provider #{inspect(name)} (known: " <>
            Enum.map_join(Map.keys(Arbiter.Agents.adapters()), ", ", &Atom.to_string/1) <> ")"}}
    end
  end

  # Kinds are a closed set (the registry), so this can safely become an atom —
  # never `String.to_atom/1` on an unbounded caller-supplied string.
  defp kind_arg(args) do
    case Map.get(args, "kind") do
      nil ->
        {:ok, nil}

      name when is_binary(name) ->
        case Enum.find(CircuitBreaker.call_sites(), &(to_string(&1.kind) == name)) do
          nil -> {:error, {:invalid, "unknown breaker kind #{inspect(name)}"}}
          site -> {:ok, site.kind}
        end

      other ->
        {:error, {:invalid, "kind must be a string, got #{inspect(other)}"}}
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, _key, false), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

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

  defp iso(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end
end
