defmodule Arbiter.MCP.Tools.Workspace do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for reading/writing workspace config and
  installation-wide settings: `workspace_show` / `workspace_config_get` /
  `workspace_config_overview` / `workspace_config_set` /
  `workspace_config_unset` / `installation_config_get` /
  `installation_config_set`. Split out of `Arbiter.MCP.Tools` (see its
  moduledoc) — called back into for the generic arg/serialization helpers it
  still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace

  @install_settings_keys ~w(
    conductor_system_max_concurrent
    credential_watchdog_adapters
    credential_watchdog_interval_ms
    credential_watchdog_recovery_interval_ms
  )

  # ---- workspace_show -----------------------------------------------------

  @doc """
  A workspace: config and the resolved worker security posture.
  Resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default. A workspace-bound scope (worker) can
  only ever inspect its own workspace.
  """
  @spec workspace_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_show(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      case Ash.get(Workspace, ws_id) do
        {:ok, %Workspace{} = ws} -> {:ok, Tools.serialize_workspace(ws)}
        _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
      end
    end
  end

  # ---- workspace_config_get ----------------------------------------------

  @doc """
  Read the full workspace config or a single dotted.key. Secret values are
  never returned — only secret_keys (the names of configured secrets) and any
  `credentials_ref` pointers already embedded in the config JSON.
  Resolved from the optional `workspace` arg, else the scope's bound workspace,
  else the installation default.
  """
  @spec workspace_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_get(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = ws.config || %{}
      key = Tools.fetch_string(args, "key")

      value =
        if key do
          config_get_in_path(config, String.split(key, "."))
        else
          config
        end

      if key != nil and value == nil do
        {:error, {:not_found, "config key not found: #{key}"}}
      else
        {:ok,
         %{
           workspace: ws.name,
           key: key,
           value: value,
           secret_keys: workspace_secret_keys(ws)
         }}
      end
    end
  end

  # ---- workspace_config_overview ------------------------------------------

  @doc """
  A grouped summary of the workspace config: tracker, merge, agent,
  review_agent, routing, review, review_gate, standing_orders, and the names
  of configured secrets (values never exposed). Mirrors `arb config overview`.
  Resolved from the optional `workspace` arg like `workspace_show`.
  """
  @spec workspace_config_overview(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_overview(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = ws.config || %{}

      {:ok,
       %{
         workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
         tracker: Map.get(config, "tracker", %{}),
         merge: Map.get(config, "merge", %{}),
         agent: Map.get(config, "agent", %{}),
         review_agent: Map.get(config, "review_agent", %{}),
         routing: Map.get(config, "routing", %{}),
         review: Map.get(config, "review", %{}),
         review_gate: Map.get(config, "review_gate", %{}),
         standing_orders: Map.get(config, "standing_orders", []),
         secret_keys: workspace_secret_keys(ws)
       }}
    end
  end

  # ---- workspace_config_set -----------------------------------------------

  @doc """
  Set a single dotted.key to a value via the deep-merge config endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved — this uses `PATCH /api/workspaces/:id/config`, not the
  whole-map replace path. Secret / credential top-level key prefixes are
  blocked; route those through `arb workspace secret`.
  Returns the workspace identity, the full updated config, and secret_keys.
  """
  @spec workspace_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_set(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, key} <- Tools.require_string(args, "key"),
         {:ok, value} <- require_config_value(args),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      patch = config_put_in_path(%{}, String.split(key, "."), value)

      case Ash.update(ws, %{patch: patch, unset_paths: []}, action: :patch_config) do
        {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- workspace_config_unset ---------------------------------------------

  @doc """
  Remove a single dotted.key from the config via the deep-merge endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved. Returns the workspace identity, the full updated config, and
  secret_keys. Errors if the key does not exist in the current config.
  """
  @spec workspace_config_unset(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_unset(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, key} <- Tools.require_string(args, "key"),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = ws.config || %{}
      path = String.split(key, ".")

      if config_get_in_path(config, path) == nil do
        {:error, {:invalid, "config key not found: #{key}"}}
      else
        case Ash.update(ws, %{patch: %{}, unset_paths: [key]}, action: :patch_config) do
          {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
          {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
        end
      end
    end
  end

  # ---- installation_config_get --------------------------------------------

  @doc """
  Read an install-wide runtime setting (bd-2ogep0) — the Conductor's system-wide
  concurrency ceiling and the `Arbiter.Agents.CredentialWatchdog` knobs
  (bd-ajgve2). Returns the full settings map when `key` is omitted. Available to
  both tiers (read-only, no workspace scoping — this is installation-wide).
  """
  @spec installation_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_get(%Scope{} = _scope, args) do
    settings = %{
      conductor_system_max_concurrent: Arbiter.Settings.conductor_system_max_concurrent(),
      credential_watchdog_adapters: Arbiter.Settings.credential_watchdog_adapters(),
      credential_watchdog_interval_ms: Arbiter.Settings.credential_watchdog_interval_ms(),
      credential_watchdog_recovery_interval_ms:
        Arbiter.Settings.credential_watchdog_recovery_interval_ms()
    }

    case Tools.fetch_string(args, "key") do
      nil ->
        {:ok, %{key: nil, value: settings, settings: settings}}

      key when key in @install_settings_keys ->
        {:ok,
         %{key: key, value: Map.get(settings, String.to_existing_atom(key)), settings: settings}}

      key ->
        {:error, {:not_found, "unknown installation setting: #{key}"}}
    end
  end

  # ---- installation_config_set --------------------------------------------

  @doc """
  Set an install-wide runtime setting (bd-2ogep0). Coordinator only (enforced
  in `Arbiter.MCP.Catalog`). `null` always clears an override, falling back to
  the application env / hardcoded default. Settable keys:

    * `conductor_system_max_concurrent` — positive integer. Takes effect on the
      next Conductor drain cycle across every running graph.
    * `credential_watchdog_adapters` — list of agent-type names
      (`Arbiter.Agents.valid_agent_types/0`) the Watchdog should probe; `[]`
      probes nothing.
    * `credential_watchdog_interval_ms` / `credential_watchdog_recovery_interval_ms`
      — positive integers.

  The Watchdog keys take effect on its next poll cycle (bd-ajgve2). No restart
  is required for any of them.
  """
  @spec installation_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_set(%Scope{} = _scope, args) do
    with {:ok, key} <- Tools.require_string(args, "key"),
         :ok <- validate_install_key(key),
         {:ok, value} <- require_install_value(key, args),
         {:ok, updated} <- put_install_setting(key, value) do
      {:ok, %{key: key, value: updated}}
    end
  end

  defp validate_install_key(key) when key in @install_settings_keys, do: :ok
  defp validate_install_key(key), do: {:error, {:invalid, "unknown installation setting: #{key}"}}

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp require_install_value("credential_watchdog_adapters", args) do
    valid = Arbiter.Agents.valid_agent_types()

    case Map.fetch(args, "value") do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, names} when is_list(names) ->
        if Enum.all?(names, &(is_binary(&1) and &1 in valid)) do
          {:ok, names}
        else
          {:error,
           {:invalid, "value must be a list of agent types (#{Enum.join(valid, ", ")}) or null"}}
        end

      {:ok, other} ->
        # Attempt to unwrap stringified JSON before failing validation
        unwrapped = Tools.unwrap_stringified_json(other, [:list])

        if is_list(unwrapped) and Enum.all?(unwrapped, &(is_binary(&1) and &1 in valid)) do
          {:ok, unwrapped}
        else
          {:error, {:invalid, "value must be a list of agent type strings or null"}}
        end

      :error ->
        {:error, {:invalid, "value is required"}}
    end
  end

  defp require_install_value(_key, args) do
    case Map.fetch(args, "value") do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:ok, other} ->
        # Attempt to unwrap stringified JSON before failing validation
        unwrapped = Tools.unwrap_stringified_json(other, [:integer])

        if is_integer(unwrapped) and unwrapped > 0 do
          {:ok, unwrapped}
        else
          {:error, {:invalid, "value must be a positive integer or null"}}
        end

      :error ->
        {:error, {:invalid, "value is required"}}
    end
  end

  defp put_install_setting(key, value) do
    result =
      case key do
        "conductor_system_max_concurrent" ->
          Arbiter.Settings.set_conductor_system_max_concurrent(value)

        "credential_watchdog_adapters" ->
          Arbiter.Settings.set_credential_watchdog_adapters(value)

        "credential_watchdog_interval_ms" ->
          Arbiter.Settings.set_credential_watchdog_interval_ms(value)

        "credential_watchdog_recovery_interval_ms" ->
          Arbiter.Settings.set_credential_watchdog_recovery_interval_ms(value)
      end

    case result do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, {:invalid, inspect(reason)}}
    end
  end

  # ---- workspace_config helpers -------------------------------------------

  # Sorted names of the workspace's configured secrets; values are never
  # returned. Mirrors ArbiterWeb.Api.WorkspaceJSON.secret_key_names/1.
  defp workspace_secret_keys(%Workspace{} = ws) do
    ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort()
  end

  # Top-level config key prefixes that the MCP write tools refuse to set.
  # Secrets live in the encrypted `secrets` column, not the config JSON;
  # routing them here would silently store a plaintext ref with no effect.
  defp deny_secret_path(key) when is_binary(key) do
    blocked = ~w(secret secrets credentials)
    prefix = key |> String.split(".") |> List.first() |> String.downcase()

    if prefix in blocked do
      {:error,
       {:unauthorized,
        "cannot set #{inspect(key)} via config tools — use `arb workspace secret` for secrets"}}
    else
      :ok
    end
  end

  # Fetch the `value` argument; accepts any JSON-decoded type (boolean,
  # integer, string, object, array, or null). Distinguishing absent from null
  # requires Map.fetch rather than Map.get.
  defp require_config_value(args) do
    case Map.fetch(args, "value") do
      :error -> {:error, {:invalid, "`value` is required"}}
      {:ok, v} -> {:ok, Tools.unwrap_stringified_json(v, [:list, :map])}
    end
  end

  # Build a nested map from a dotted-path segment list and a leaf value.
  defp config_put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  defp config_put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, config_put_in_path(sub, rest, value))
  end

  # Navigate a nested config map by path segments; nil if any segment is missing.
  defp config_get_in_path(value, []), do: value

  defp config_get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> config_get_in_path(sub, rest)
    end
  end

  defp config_get_in_path(_, _), do: nil

  # The standard config result: workspace identity, full (secret-safe) config,
  # and the names of configured secrets so the caller can confirm the merge.
  defp serialize_workspace_config(%Workspace{} = ws) do
    %{
      workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
      config: ws.config || %{},
      secret_keys: workspace_secret_keys(ws)
    }
  end
end
