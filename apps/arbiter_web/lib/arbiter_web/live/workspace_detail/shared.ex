defmodule ArbiterWeb.WorkspaceDetail.Shared do
  @moduledoc """
  Config-reading and config-writing primitives shared by the workspace detail
  page's section components.

  Only what more than one section needs lives here: the free-form JSON readers
  (`cfg/3`, `config_map/2`), the three Ash write paths, the error flattener,
  and the two notifications a section sends back up to
  `ArbiterWeb.WorkspaceDetailLive` (`notify_workspace/1`, `notify_flash/2`).
  A helper only one section uses stays private to that section.

  ## Why sections talk to the parent at all

  Every section renders off the same `Arbiter.Tasks.Workspace` record, and a
  write in one is visible in another — setting a secret changes the
  `credentials_ref` options in both the tracker and agent-model sections; saving
  the config form changes which tracker adapter fields exist. So the parent
  LiveView stays the single owner of `@workspace`: a component writes, assigns
  the fresh record locally so its own render is immediate, and sends it up so
  every sibling re-renders from the same record.

  Flash is a separate message rather than a `put_flash/3` inside the component
  because a LiveComponent has its *own* `@flash` assign (`Phoenix.LiveView.Diff`
  seeds it to `%{}` at mount) and it is only merged into the page's flash on a
  redirect — a flash raised in a component and never redirected would simply
  never be seen under `Layouts.app`.
  """

  alias Arbiter.Tasks.Workspace

  @doc """
  Reads a dotted config path, falling back to `default` for a missing value.
  """
  def cfg(ws, path, default \\ nil) do
    case get_in(ws.config || %{}, path) do
      nil -> default
      v -> v
    end
  end

  @doc """
  A nested config map, or `%{}` for anything that isn't one.

  `agent.config` and friends are free-form JSON, so a scalar at any level is
  possible and must not crash the page.
  """
  def config_map(ws, path) do
    Enum.reduce(path, ws.config || %{}, fn key, acc ->
      case acc do
        %{} = map -> Map.get(map, key, %{})
        _ -> %{}
      end
    end)
    |> case do
      %{} = map -> map
      _ -> %{}
    end
  end

  @doc """
  Applies a deep-merge patch (plus explicit unsets) through `:patch_config`,
  so the server-side `ValidateConfig` guardrails apply exactly as they do for
  the API controller and the CLI.
  """
  def patch_config(ws, patch, unset_paths) do
    case Ash.update(ws, %{patch: patch, unset_paths: unset_paths}, action: :patch_config) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, error_message(err)}
    end
  end

  @doc """
  The workspace's configured secret *names*, sorted. Never values — those are
  write-only. Sections derive this from the workspace record they hold rather
  than taking it as a prop, so a section that writes a secret shows it in the
  same render.
  """
  def secret_keys(%Workspace{} = ws),
    do: ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort()

  @doc "Write-only secret set/remove (a `nil` value removes the key)."
  def set_secrets(ws, secrets) do
    case Ash.update(ws, %{secrets: secrets}, action: :update) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, error_message(err)}
    end
  end

  @doc "Worker env var set/remove (a `nil` value removes the key)."
  def set_worker_env(ws, patch) do
    case Ash.update(ws, %{worker_env: patch}, action: :update) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, error_message(err)}
    end
  end

  def error_message(%Ash.Error.Invalid{errors: errors}) do
    errors |> Enum.map_join("; ", &Exception.message/1)
  end

  def error_message(err), do: Exception.message(err)

  @doc """
  Hands a freshly-written workspace record to the parent LiveView so every
  other section re-renders from it. See the module doc.
  """
  def notify_workspace(%Workspace{} = ws), do: send(self(), {:workspace_updated, ws})

  @doc """
  Raises a page-level flash from inside a section. See the module doc for why
  `put_flash/3` on the component socket is not enough.
  """
  def notify_flash(kind, message) when kind in [:info, :error],
    do: send(self(), {:workspace_flash, kind, message})

  @doc """
  Assigns a written workspace locally *and* notifies the parent — the shape
  every successful section write ends in.
  """
  def apply_workspace(socket, ws, flash \\ nil) do
    notify_workspace(ws)
    if flash, do: notify_flash(:info, flash)
    Phoenix.Component.assign(socket, :workspace, ws)
  end

  def maybe_put_map(patch, _key, empty) when empty == %{}, do: patch
  def maybe_put_map(patch, key, value), do: Map.put(patch, key, value)

  def blank_to_nil(nil), do: nil

  def blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil

  @doc """
  A single `routing.rules[tier]` / `routing.adapters[]` entry — the
  provider-agnostic `model_tier`/`thinking` abstraction `ByDifficulty` and
  `RoundRobin` know about, plus a raw `model` escape hatch for power users
  bypassing the abstraction (same precedent as `ByPriority`'s example).
  Blank fields are omitted rather than written empty.
  """
  def routing_entry_fields(params) do
    %{}
    |> maybe_put_entry_field(params, "model_tier")
    |> maybe_put_entry_field(params, "thinking")
    |> maybe_put_entry_field(params, "model")
  end

  defp maybe_put_entry_field(map, params, key) do
    case blank_to_nil(params[key]) do
      nil -> map
      v -> Map.put(map, key, v)
    end
  end

  def routing_entry_summary(entry) when is_map(entry) and map_size(entry) > 0 do
    entry |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
  end

  def routing_entry_summary(_entry), do: "(empty)"

  @doc """
  `credentials_ref` is picked from the workspace's own secret registry — the
  page never offers a box a raw token could be pasted into. A ref set outside
  the dashboard (typically `env:NAME`) is carried as an extra option so opening
  a form and saving can't silently drop it.
  """
  def credentials_ref_options(secret_keys, current) do
    options = [{"(unset)", ""} | Enum.map(secret_keys, &{"secret:#{&1}", "secret:#{&1}"})]

    if current == "" or Enum.any?(options, fn {_label, value} -> value == current end) do
      options
    else
      options ++ [{"#{current} (set outside the dashboard)", current}]
    end
  end
end
